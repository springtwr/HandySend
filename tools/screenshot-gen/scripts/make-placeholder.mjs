// 生成三端占位素材：设备框 PNG（边框内侧为透明屏幕区）与 raw 截图占位，供冒烟测试使用。
// 冒烟使用独立可丢弃工作区：raw 占位写入 --raw-dir 指定的目录（缺省 raw-smoke，相对工具目录解析），
// 每次运行先清空再重建，结果确定性可重复；真实 raw/ 目录永不被本脚本写入任何文件。
// 占位 raw 仅为 shots 前两条特性生成：第一条（compat）输出 .png、第二条（mta）输出 .jpg，
// 其余条目缺图走特性图路径——三者分别覆盖 png→截图、jpg→截图、无图→特性图三条识别路径。
// 设备框占位（assets/frames/<端>.png）遵循"目标缺失才生成"：真实素材保留原样，已存在时跳过。
// 语言直接读取 config.json，保持与正式配置同步。
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const toolRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(readFileSync(resolve(toolRoot, 'config.json'), 'utf8'));

// 占位设备框规格：画布尺寸与边框宽度（像素），边框内侧为透明屏幕区。
const FRAME_SPECS = [
  { name: 'phone', width: 1000, height: 2000, border: 40 },
  { name: 'tablet', width: 2000, height: 1400, border: 70 },
  { name: 'pc', width: 2000, height: 1250, border: 50 },
];

// 占位 raw 截图规格：尺寸刻意与屏幕区域宽高比不同，以验证 cover 等比裁剪。
const RAW_SPECS = [
  { platform: 'phone', width: 1080, height: 2400, color: '#3d7ee0' },
  { platform: 'tablet', width: 2560, height: 1600, color: '#37a06b' },
  { platform: 'pc', width: 1920, height: 1200, color: '#c9803a' },
];

/** 解析 --raw-dir 参数：返回 raw 占位工作区目录（相对工具目录解析）；缺省 raw-smoke */
function parseRawDir(argv) {
  const flagIndex = argv.indexOf('--raw-dir');
  if (flagIndex !== -1) {
    const value = argv[flagIndex + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error('--raw-dir 需要一个目录参数（如 --raw-dir raw-smoke）');
    }
    return value;
  }
  return 'raw-smoke';
}

/** 生成单个占位设备框：纯色边框 + 透明中心；目标文件已存在时跳过 */
async function makeFrame(browser, spec) {
  const outputPath = resolve(toolRoot, 'assets', 'frames', `${spec.name}.png`);
  // 只补缺不覆盖：已存在的设备框素材（真实或上次占位）一律保留
  if (existsSync(outputPath)) {
    console.log(`已存在，跳过占位（保留现有素材）：${outputPath}`);
    return;
  }
  const page = await browser.newPage({
    viewport: { width: spec.width, height: spec.height },
    deviceScaleFactor: 1,
  });
  await page.setContent(
    `<!DOCTYPE html>
     <html>
     <head><meta charset="UTF-8"><style>
       * { margin: 0; padding: 0; }
       html, body { width: 100%; height: 100%; overflow: hidden; }
       .border { position: absolute; inset: 0; box-sizing: border-box; border: ${spec.border}px solid #263238; }
     </style></head>
     <body><div class="border"></div></body>
     </html>`,
  );
  // omitBackground 保留页面透明背景，使边框内侧成为透明屏幕区
  await page.screenshot({
    path: outputPath,
    clip: { x: 0, y: 0, width: spec.width, height: spec.height },
    omitBackground: true,
  });
  await page.close();
  console.log(`已生成占位设备框：${outputPath}`);
}

/** 生成单张占位 raw 截图：纯色底 + 居中标注文字；输出格式由扩展名（ext）决定，png 或 jpg。
 *  工作区每次已清空重建，raw 占位无条件生成，无需存在性检查 */
async function makeRaw(browser, spec, locale, feature, ext, rawRoot) {
  const rawDir = resolve(rawRoot, spec.platform, locale);
  // page.screenshot 依据路径扩展名推断输出格式：.jpg 后缀即输出 JPEG
  const outputPath = resolve(rawDir, `${feature}.${ext}`);
  const page = await browser.newPage({
    viewport: { width: spec.width, height: spec.height },
    deviceScaleFactor: 1,
  });
  await page.setContent(
    `<!DOCTYPE html>
     <html>
     <head><meta charset="UTF-8"><style>
       * { margin: 0; padding: 0; }
       html, body { width: 100%; height: 100%; overflow: hidden; }
       body {
         background: ${spec.color};
         display: flex;
         align-items: center;
         justify-content: center;
         color: #ffffff;
         font-family: system-ui, 'Noto Sans CJK SC', 'Microsoft YaHei', sans-serif;
         font-size: 96px;
         font-weight: 700;
       }
     </style></head>
     <body>占位截图 ${spec.platform} ${locale} ${feature}</body>
     </html>`,
  );
  mkdirSync(rawDir, { recursive: true });
  await page.screenshot({
    path: outputPath,
    clip: { x: 0, y: 0, width: spec.width, height: spec.height },
  });
  await page.close();
  console.log(`已生成占位截图：${outputPath}`);
}

async function main() {
  // 冒烟工作区每次运行清空重建，保证结果确定性可重复；遗留文件不参与任何真实生成
  const rawRoot = resolve(toolRoot, parseRawDir(process.argv.slice(2)));
  rmSync(rawRoot, { recursive: true, force: true });

  const browser = await chromium.launch();
  try {
    mkdirSync(resolve(toolRoot, 'assets', 'frames'), { recursive: true });
    for (const spec of FRAME_SPECS) {
      await makeFrame(browser, spec);
    }
    // 前两条特性生成占位 raw：第一条输出 .png、第二条输出 .jpg，其余条目缺图走特性图路径
    const placeholders = [
      { feature: config.shots[0], ext: 'png' },
      { feature: config.shots[1], ext: 'jpg' },
    ];
    for (const locale of config.locales) {
      for (const spec of RAW_SPECS) {
        for (const { feature, ext } of placeholders) {
          await makeRaw(browser, spec, locale, feature, ext, rawRoot);
        }
      }
    }
  } finally {
    await browser.close();
  }
  console.log('占位素材生成完毕');
}

main().catch((err) => {
  console.error(`错误：${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
