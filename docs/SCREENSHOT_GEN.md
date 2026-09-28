# 预览图生成工具 screenshot-gen 使用说明

> `tools/screenshot-gen/` 是一个独立的 Node.js 命令行工具，用于把设备截图合成为应用市场（AGC）三端上架预览图：叠加设备框与标题文案，并按精确尺寸导出 PNG。工具独立于
> HarmonyOS 应用构建流程，不参与应用打包，运行环境为开发者本机（要求 Node.js ≥ 18；无平台特定依赖，Windows / macOS / Linux 均可运行，目前在 Linux 上开发验证）。

## 1. 工作方式

一次运行完成指定语言（缺省为全部语言）三端全部预览图的生成：

1. 读取 `tools/screenshot-gen/config.json`（语言清单、特性文案、预览图序列、三端输出尺寸、设备框素材、屏幕区域坐标）；
2. 渲染前一次性校验配置结构与全部引用文件，任何缺失立即报错退出、不产出文件；
3. 用 Playwright 无头 Chromium 加载三端 HTML 模板，将 raw 截图（`.png` 或 `.jpg`，PNG 优先）以等比缩放居中裁剪（`object-fit: cover`）填入设备框屏幕区域，叠加标题/副标题文案；
4. 按端与语言导出到 `output/<端>/<语言>/<特性>.png`，尺寸精确等于配置的 `outputSize`。

预览图序列（`shots`）为三端共享的特性 id 有序列表，每条引用 `features` 中的一个特性；渲染风格按 raw 截图是否存在自动推导：

- 存在 `raw/<端>/<语言>/<特性>.png`（无 `.png` 时存在 `.jpg` 亦可）：渲染为 `screenshot` 风格——设备框内嵌截图，叠加标题/副标题；
- `.png` 与 `.jpg` 均缺失：自动退化为 `feature` 特性图——不渲染设备框与截图，文案放大后居中占满画布，配线性图标、
  胶囊标签、柔光圆与点阵装饰。输出摘要中对退化产物标注「（无截图，特性图）」，便于发现文件名笔误导致的意外降级。

三端布局：手机端与平板端为竖排（上方文案、下方设备框），2in1 端为横排（左侧设备框、右侧文案）；`feature` 风格下三端均为文案居中。

冒烟与真实生成彻底隔离：`npm run smoke` 使用独立可丢弃工作区 `raw-smoke/`（gitignore），占位素材只写入该工作区且每次运行清空重建，真实 `raw/` 目录不被冒烟写入或覆盖任何文件；
真实 `npm run generate` 只读取真实 `raw/`，raw 截图稀疏提供（仅部分端/语言组合有真实图）时，缺真实图的组合自动退化为特性图，不使用任何占位图。

## 2. 安装

在 `tools/screenshot-gen/` 目录下执行：

```bash
npm install
npx playwright install chromium
```

首次运行前必须完成上述两步；Chromium 由 Playwright 下载到 `~/.cache/ms-playwright/`。

## 3. 目录结构

```text
tools/screenshot-gen/
├── package.json          # 依赖与 npm scripts
├── tsconfig.json
├── config.json           # 唯一内容来源：语言、特性文案、预览图序列、尺寸、素材、坐标
├── src/                  # 工具源码（TypeScript，经 tsx 直接运行；icons.ts 为特性图图标集）
├── templates/            # 三端 HTML 模板与共享样式
├── scripts/              # 占位素材生成、输出尺寸校验脚本
├── assets/frames/        # 设备框透明 PNG
│   ├── phone.png
│   ├── tablet.png
│   └── pc.png
├── raw/                  # 截图输入（`.png` 与 `.jpg` 双格式，PNG 优先），按端与语言分子目录（gitignore）
│   ├── phone/<语言>/
│   ├── tablet/<语言>/
│   └── pc/<语言>/
├── raw-smoke/            # 冒烟工作区（gitignore，可丢弃）：每次冒烟清空重建，占位素材只写入此处
└── output/               # 生成产物，按端与语言分子目录（gitignore）
    ├── phone/<语言>/
    ├── tablet/<语言>/
    └── pc/<语言>/
```

`raw/`、`raw-smoke/`、`output/`、`node_modules/` 均在仓库 `.gitignore` 中，不入库。

## 4. raw 截图采集约定

- 截图由开发者自行截取（DevEco Studio 截屏或系统截屏），截图采集自动化不在工具范围内。
- raw 路径按约定推导：`raw/<端>/<语言>/<特性>.png` 或 `.jpg`（同一条目两种格式并存时优先使用 `.png`），
  文件名即 `shots` 中的特性 id（如 `raw/phone/zh_Hans/compat.png`）；输出文件名与之一致，二者可追溯对应。
- 每种语言（简体中文 / 繁体中文 / 英文）需在对应应用语言下各截一套截图；缺少某语言某特性的截图时，对应预览图自动退化为特性图（不报错），可用 `--locale` 只生成指定语言。
- 截图宽高比与设备框屏幕区域不一致时，工具自动等比缩放居中裁剪填充，不会拉伸变形。
- 状态栏时间：截图前在设备系统设置中手动调整（需先关闭「自动设置时间」，否则修改会被网络时间同步覆盖），一批截图保持同一固定时间（如 09:41）。电量在充满后一批截图内不会变化，无需控制。
- 平板/2in1 无对应真机时采用混合策略：能截图的条目用模拟器界面截图，其余预览图缺 raw 自动退化为特性图。
  模拟器无蓝牙导致主页面显示「互传联盟需要蓝牙」横幅时，可在应用「设置 → 互传联盟（MTA）→ 互传连接提醒」中临时关闭后再截图。

## 5. config.json 字段说明

```json
{
  "locales": ["zh_Hans", "zh_Hant", "en"],
  "localeConfigs": {
    "zh_Hans": { "fontFamily": "'HarmonyOS Sans SC', 'Noto Sans CJK SC', sans-serif" }
  },
  "features": {
    "mta": {
      "icon": "mta",
      "text": {
        "zh_Hans": { "tag": "互传联盟 MTA", "title": "支持互传联盟", "subtitle": "……" }
      }
    }
  },
  "shots": ["compat", "mta"],
  "platforms": {
    "phone": {
      "outputSize": { "width": 1080, "height": 1920 },
      "frame": {
        "image": "assets/frames/phone.png",
        "screenArea": { "x": 0.04, "y": 0.02, "width": 0.92, "height": 0.96 },
        "radius": 0.111
      }
    }
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `locales` | array | 语言代码列表（如 `zh_Hans`），至少一个；语言代码仅允许字母、数字、下划线、连字符 |
| `localeConfigs` | object | 各语言的可选配置；`fontFamily` 为 CSS `font-family` 值，覆盖模板默认字体栈 |
| `features.<特性id>` | object | 特性条目；特性 id 仅允许字母、数字、下划线、连字符 |
| `features.<id>.icon` | string，可选 | 特性图线性图标名，须为 `src/icons.ts` 中定义的图标（link、mta、qr、share、bolt、tasks、background） |
| `features.<id>.text.<语言>` | object | 该语言的文案，必须覆盖 `locales` 全部语言，不允许多余语言键 |
| `text.<语言>.title` | string | 标题文案，必填；主标题以鸿蒙黑体 Bold 渲染 |
| `text.<语言>.subtitle` | string，可选 | 副标题文案；以鸿蒙黑体 Regular 渲染，空串视为未提供 |
| `text.<语言>.tag` | string，可选 | 特性图胶囊标签，仅特性图风格渲染，空串视为未提供 |
| `shots` | array | 三端共享的预览图序列，元素为特性 id 字符串，至少 1 条；条目数即每端每语言的输出张数；同一特性只能出现一次（否则输出文件名冲突）；渲染风格按 raw 截图存在与否自动推导 |
| `platforms` | object | 三端配置，`phone` / `tablet` / `pc` 三端必须齐备 |
| `platforms.<端>.outputSize` | object | 输出画布像素尺寸，`width` / `height` 均为正整数 |
| `platforms.<端>.frame.image` | string | 设备框 PNG 路径，相对工具目录；应为透明背景素材 |
| `platforms.<端>.frame.screenArea` | object | 框内屏幕区域，归一化坐标（见下） |
| `platforms.<端>.frame.radius` | number，可选 | 屏幕开孔圆角半径，归一化到框图宽度（见下）；缺省 0 表示直角开孔 |

### screenArea 归一化坐标

`screenArea` 描述设备框 PNG 中"屏幕"（截图应填入的区域）的位置与尺寸，四个值均为 **0–1 的比例值，相对框图像自身的宽高**，与框图分辨率无关：

- `x`、`y`：屏幕区域左上角到框图左上角的距离，分别除以框图宽、高；
- `width`、`height`：屏幕区域的宽、高，分别除以框图宽、高。

**获取方法**：用任意图像工具（GIMP、PNG 查看器等）打开设备框 PNG，量出屏幕区域的像素位置与尺寸，再除以框图总宽高。例如框图 1000×2000，屏幕区域距左 40px、距上 40px、宽 920px、高 1920px，则：

```text
x = 40/1000 = 0.04    y = 40/2000 = 0.02
width = 920/1000 = 0.92    height = 1920/2000 = 0.96
```

约束：`x + width` 与 `y + height` 不得超过 1（屏幕区域不得越出框图）。

### radius 开孔圆角

`radius` 描述设备框屏幕开孔的圆角半径，为 **0–1 的比例值，相对框图宽度**。渲染时截图区域会按此半径裁剪四角，避免直角截图从圆角开孔中露出。
获取方法：量出开孔圆角半径的像素值后除以框图宽度，例如框图宽 1383px、圆角半径约 155px，则 `radius = 155/1383 ≈ 0.111`。开孔为直角时省略该字段即可。

更换设备框素材时，替换 `assets/frames/` 下的 PNG 并按新框重新标注 `screenArea`（必要时同步更新 `radius`）即可，无需改动任何代码。

## 6. 运行命令

在 `tools/screenshot-gen/` 目录下执行：

```bash
# 生成全部语言的全部预览图（读取 config.json 与 raw/ 截图）
npm run generate

# 只生成一种语言
npm run generate -- --locale zh_Hans

# 一键冒烟：生成占位素材 → 全语言生成 → 校验输出 PNG 尺寸
npm run smoke
```

- `generate` 成功时打印每语言每端张数与产物路径，缺 raw 的条目标注「（无截图，特性图）」；重复运行直接覆盖同名产物。
- `--locale` 的值须为 `config.json` 的 `locales` 中声明的语言，否则报错并列出可用语言。
- `check-size`（`node scripts/check-size.mjs`）单独运行时按语言 × 端 × 条目校验既有产物尺寸与 `outputSize` 一致，不依赖图像库。
- `smoke` 会先执行占位素材脚本 `scripts/make-placeholder.mjs`，该脚本使用独立可丢弃工作区 `raw-smoke/`（gitignore）：每次运行清空重建，占位素材（`shots` 前两条特性：首条生成
  `.png`、第二条生成 `.jpg`，覆盖 png/jpg/无图三条识别路径）只写入工作区，真实 `raw/` 目录不被写入或覆盖任何文件；`smoke` 的生成与尺寸校验均以工作区为输入。真实
  `generate`（`npm run generate`）只读取真实 `raw/`，raw 截图稀疏提供时缺真实图的组合自动退化为特性图。设备框占位仅在 `assets/frames/` 目标缺失时生成，已存在的设备框保持原样。

## 7. 常见调整

| 需求 | 操作 |
|---|---|
| AGC 尺寸规格变化 | 修改对应端 `outputSize`，仅此一处；画布与模板布局自适应 |
| 版本更新换截图 | 替换 `raw/<端>/<语言>/` 下的截图（`.png` 或 `.jpg`，文件名不变则配置不动） |
| 修改文案 | 修改对应特性在 `features.<id>.text.<语言>` 中的 `title` / `subtitle` / `tag` |
| 新增语言 | `locales` 增加语言代码，为每个特性补充该语言文案，采集该语言截图 |
| 更换设备框 | 替换 `assets/frames/` 下的 PNG 并更新该端 `screenArea`。pc 端文案区压在框图右侧空白上，新框图右侧须保留约一成宽度的透明留白，否则需调整 `pc.html` 中文案区定位 |
| 增删预览图 | 增删顶层 `shots` 中的特性 id（引用已有或新增特性）；删去某条的 raw 截图即令该条退化为特性图 |
| 新增特性图图标 | 在 `src/icons.ts` 中添加 SVG 字符串，特性条目通过 `icon` 字段引用 |
| 调整布局/配色 | 修改 `templates/` 下对应端模板或 `templates/shared.css` |

除「新增特性图图标」外均不涉及工具源码（`src/`）改动。

## 8. 字体依赖

文案渲染字体由 `localeConfigs.<语言>.fontFamily` 指定，按语言使用鸿蒙黑体（HarmonyOS Sans）：

- 简体中文：`HarmonyOS Sans SC`（主标题 Bold 字重、副标题 Regular 字重）
- 繁体中文：`HarmonyOS Sans TC`
- 英文：`HarmonyOS Sans`

开发机需安装对应字体（本机 Linux 位于 `/usr/share/fonts/harmonyos-sans/`，Windows / macOS
按各自方式安装后由系统字体名解析），缺字重时会按字体栈逐级回退（`Noto Sans CJK SC/TC`、`sans-serif`）。工具不打包字体文件。

## 9. 错误处理

渲染前一次性完成全部校验，任何一项失败即打印错误并以非零退出码结束，不产出任何结果文件：

| 场景 | 报错内容 |
|---|---|
| 设备框素材缺失 | 缺失文件的绝对路径与 `platforms.<端>.frame.image` |
| 模板/样式缺失 | 缺失文件的绝对路径 |
| 配置字段缺失或类型错误 | JSON 路径（如 `features.mta.text.zh_Hans.title`）与具体原因 |
| 特性文案缺语言 | JSON 路径与「字段缺失」 |
| 特性引用不存在 / 重复 | `shots` 中具体条目与原因 |
| 图标名未知 | 特性位置、错误图标名与全部可用图标名 |
| `--locale` 参数错误 | 参数格式错误或未知语言（列出可用语言） |
| 配置解析失败 | 解析错误的行列位置 |
| 渲染布局偏差 | 画布尺寸或屏幕区域实际值与期望值（容差 1px） |

raw 截图缺失（`.png` 与 `.jpg` 均不存在）不报错：对应预览图自动退化为特性图，输出摘要标注「（无截图，特性图）」。

渲染阶段内置布局自检：每张图导出前比对画布尺寸与屏幕区域换算位置，偏差超过 1px 即报错，避免尺寸或坐标错位的产物静默输出。
