# 多语言支持方案（i18n）

QuickMD 目前只有英文界面。本方案用 macOS 原生本地化机制接入多语言，**第一批交付简体中文（zh-Hans）**，并保证对现有代码的改动尽可能小。

## 1. 目标与非目标

**目标**

- 界面文字（菜单、设置、弹窗、边栏、提示、工具提示、无障碍标签、错误信息）跟随系统语言。
- 新增语言不需要改 Swift 代码，只需要新增 `.lproj/Localizable.strings`。
- 同时兼容 Xcode 构建和 `scripts/clt-build.sh`（仅 Command Line Tools）构建。
- 不改变现有文档解析、渲染和导出逻辑；不翻译用户文档内容。

**非目标**

- 不在 App 内自建语言切换器：使用 macOS 原生的「系统设置 → 通用 → 语言与地区 → 应用程序」按 App 设置语言。
- 不翻译 Markdown 文档正文、代码、主题名称（Solarized、Dracula 等产品名）、编辑器 App 名称、编码名（UTF-8、ISO Latin 1）和文件名。
- 本阶段不做 App Store 商店文案、README 的多语言版本。

## 2. 技术选型

| 方案 | 结论 | 原因 |
|------|------|------|
| `Localizable.strings` + `.lproj` | **采用** | macOS 原生；Xcode 与 `clt-build.sh` 都能处理；SwiftUI 字面量自动生效，零调用点改动 |
| String Catalog（`.xcstrings`） | 不采用 | 需要 Xcode 的 `xcstringstool` 编译；本仓库的 CLT 构建脚本只复制 `.lproj`，会丢失翻译 |
| 运行时代码内字典 | 不采用 | 每个 `Text` 都要改，且无法覆盖 AppKit 菜单/弹窗与系统无障碍链路，改动反而最大 |

开发语言保持 `en`。英文源文本就是翻译键（source-string key），因此：

- `Text("Save")` 这类 SwiftUI 字面量无需任何代码改动，自动查 `Localizable.strings`。
- 英文缺失时自然回退到键本身，也就是英文。

## 3. 文件与工程配置

```
QuickMD/QuickMD/
├── L10n.swift                       # 显式查找辅助函数（很小）
├── en.lproj/
│   └── Localizable.strings          # 英文基准（键 = 值）
└── zh-Hans.lproj/
    └── Localizable.strings          # 简体中文
```

- `project.pbxproj`
  - `knownRegions` 增加 `"zh-Hans"`；
  - `Localizable.strings` 以 `PBXVariantGroup` 加入 Resources；
  - `L10n.swift` 同时加入 App 与测试 target（测试直接编译部分 App 源文件）。
- `Info.plist` 的 `CFBundleDevelopmentRegion` 继续使用 `$(DEVELOPMENT_LANGUAGE)`（即 `en`）。
- `scripts/clt-build.sh` 已经会复制源码目录下的所有 `*.lproj`，**无需修改构建脚本**。

## 4. 两层本地化约定

### 4.1 SwiftUI 自动本地化（不改代码）

以下字面量已经是 `LocalizedStringKey`，直接写入 `Localizable.strings` 即可：

```swift
Text("Documents")
Button("Save")
Label("General", systemImage: "gearshape")
Toggle("Copy selected text automatically", isOn: $on)
Picker("Theme", selection: $name) { … }
TextField("Search...", text: $text)
.help("Copy code")
.accessibilityLabel("Support")
```

注意：**变量或三元表达式会被推断成 `String`，不走本地化**。这类必须显式 `L(...)`：

```swift
// 不会本地化
Text(isParsing ? "Parsing…" : "Rendering…")
Button(status)
Text(choice.title)              // title 是 String

// 会本地化
Text(isParsing ? L("Parsing…") : L("Rendering…"))
Button(L("Update Available — v%@", latest))
Text(L("No headings up to H%lld", level))
```

### 4.2 显式 `L()`（AppKit / 动态字符串）

`L10n.swift` 只有一个函数：

```swift
func L(_ key: String, _ arguments: CVarArg...) -> String
```

用于 SwiftUI 看不见的文本：

- `NSAlert.messageText` / `informativeText` / `addButton(withTitle:)`
- `NSOpenPanel` / `NSSavePanel` 的 `title`、`message`、`prompt`
- `NSMenuItem` 标题（右键菜单）
- Toast、状态栏、撤销动作名
- `LocalizedError.errorDescription` / `failureReason` / `recoverySuggestion`
- 任何先拼成 `String`、再交给 View 的内容

示例：

```swift
alert.messageText = L("Open “%@:” link?", scheme)
showToast(L("Zoom %lld%%", Int((next * 100).rounded())))
undoManager.setActionName(L("Paste"))
```

`L()` 内部使用 `NSLocalizedString`；无参数时直接返回查找结果，有参数时用 `String(format:)`。因此翻译可以调整语序：

```swift
L("Opened in %@ at line %lld", appName, line)
// zh-Hans: "已在 %@ 中打开，位于第 %lld 行"
```

## 5. 键与占位符规则

1. **键必须是英文源文本，逐字节一致**。包括：
   - 弯引号 `“ ” ’`、省略号 `…`、破折号 `—`、中点 `·`
   - 快捷键符号 `⌘ ⌥ ⇧`
   - 句末标点（`Find...` 在源码里是三个点，不是 `…`）
   - 行尾无空格
2. 占位符：
   - `%@`：字符串
   - `%lld`：整数（不要用 `%d`，Swift 的 `Int` 是 64 位）
   - `%%`：字面百分号
   - `\n`：换行
3. 不要把可变内容写进键。键里只保留占位符，例如 `"Opened in %@ at line %lld"`，不要写 `"Opened in Zed at line 42"`。
4. 同名键只允许出现一次；不同语境需要不同译文时，改用更完整的英文句子作键，而不是加 `key.` 前缀（保持 SwiftUI 字面量零改动）。
5. 译文可以调整占位符周围的语序，但**占位符的出现顺序、种类和数量必须一致**；否则参数会错位。需要换序时请使用位置参数（如 `%1$@`、`%2$lld`），并确认所有语言一致。

## 6. 新增语言的步骤

以加入日语为例：

1. 新建 `QuickMD/QuickMD/ja.lproj/Localizable.strings`，从 `en.lproj` 复制全部键。
2. 翻译值，保持占位符不变。
3. 在 Xcode 中把该文件加入 `Localizable.strings` 变体组（或手工在 `project.pbxproj` 增加一个 `PBXFileReference` 子项）。
4. 在 `knownRegions` 中加入 `ja`。
5. 运行 `python3 scripts/check-localizations.py`。
6. 构建并验证（见下节）。

不需要改任何 Swift 文件；`L()` 和 SwiftUI 会自动选择新语言。

## 7. 测试与验证

**静态检查**

```bash
python3 scripts/check-localizations.py
```

检查：键集合是否一致、是否有重复键、占位符是否一一对应、译文是否为空。

**构建**

```bash
./scripts/clt-build.sh build Debug
```

产物中应存在：

```
.build/clt/Debug/QuickMD.app/Contents/Resources/en.lproj/Localizable.strings
.build/clt/Debug/QuickMD.app/Contents/Resources/zh-Hans.lproj/Localizable.strings
```

**运行时**

1. 系统设置为简体中文，或只对 QuickMD 设置：
   「系统设置 → 通用 → 语言与地区 → 应用程序 → QuickMD → 简体中文」。
2. 也可以用临时 defaults 验证（重启 App 生效）：

   ```bash
   defaults write pl.falami.studio.QuickMD AppleLanguages -array zh-Hans
   defaults delete pl.falami.studio.QuickMD AppleLanguages   # 验证完恢复
   ```

3. 重点检查：菜单、设置四个标签页、搜索栏、目录/最近文档边栏、打开链接确认框、源文件编辑的未保存/冲突/编码弹窗、导出 PDF 与打印错误框、图片加载占位符、右键菜单。

## 8. 最小化改动的边界

- 没有引入 ViewModel、资源包、依赖或新的架构层。
- 视图里的静态文案完全不动；只改「SwiftUI 推断不出 `LocalizedStringKey`」的调用点。
- AppKit 弹窗、`NSMenu`、错误类型和 toast 是主要改动面。
- 文档内容、主题名、编辑器名保持原样，避免误翻和持久化键变化。

## 9. 已知限制与后续

- **无 App 内语言切换器**：遵循 macOS 按 App 语言设置，避免自建语言状态与系统菜单不一致。
- **Info.plist 文稿类型名称**（Finder 中的 “Markdown Document” / “Plain Text”）无法通过 `InfoPlist.strings` 数组键本地化；如未来需要，应改为 `InfoPlist.xcstrings` + Xcode 构建。
- **复数**：当前只有 “1 character / N characters” 一组，中文无复数变化；未来语言（如俄语）需要改为 `stringsdict` 或 String Catalog 的 plural 变体。
- **RTL**：本阶段只有 zh-Hans；后续加入阿拉伯语/希伯来语时需要检查布局镜像。
- **日期、数字、字节大小**已经由 Foundation 按系统区域格式化，不在本方案范围内。
