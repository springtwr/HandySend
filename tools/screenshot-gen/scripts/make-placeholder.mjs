// 生成三端占位素材：设备框 PNG（边框内侧为透明屏幕区）与 raw 截图 PNG，供冒烟测试使用。
// 占位 raw 仅为 shots 首条特性生成（其余条目缺图，自动走特性图路径），
// 使冒烟测试同时覆盖截图与特性图两条渲染路径；语言直接读取 config.json，保持与正式配置同步。
// 注意：本脚本会覆盖 assets/frames/ 下的占位设备框与 raw/ 下的占位截图；
// 放入真实设备框素材后请勿再运行本脚本或 npm run smoke（smoke 会先执行本脚本）。
import { mkdirSync, readFileSync } from 'node:fs';
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

/** 生成单个占位设备框：纯色边框 + 透明中心 */
async function makeFrame(browser, spec) {
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
  const outputPath = resolve(toolRoot, 'assets', 'frames', `${spec.name}.png`);
  // omitBackground 保留页面透明背景，使边框内侧成为透明屏幕区
  await page.screenshot({
    path: outputPath,
    clip: { x: 0, y: 0, width: spec.width, height: spec.height },
    omitBackground: true,
  });
  await page.close();
  console.log(`已生成占位设备框：${outputPath}`);
}

/** 生成单张占位 raw 截图：纯色底 + 居中标注文字 */
async function makeRaw(browser, spec, locale, feature) {
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
  const rawDir = resolve(toolRoot, 'raw', spec.platform, locale);
  mkdirSync(rawDir, { recursive: true });
  const outputPath = resolve(rawDir, `${feature}.png`);
  await page.screenshot({
    path: outputPath,
    clip: { x: 0, y: 0, width: spec.width, height: spec.height },
  });
  await page.close();
  console.log(`已生成占位截图：${outputPath}`);
}

async function main() {
  const browser = await chromium.launch();
  try {
    mkdirSync(resolve(toolRoot, 'assets', 'frames'), { recursive: true });
    for (const spec of FRAME_SPECS) {
      await makeFrame(browser, spec);
    }
    // 首条特性生成占位 raw（渲染为截图），其余条目缺图走特性图路径
    const firstFeature = config.shots[0];
    for (const locale of config.locales) {
      for (const spec of RAW_SPECS) {
        await makeRaw(browser, spec, locale, firstFeature);
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
