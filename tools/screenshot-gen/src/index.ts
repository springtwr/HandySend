// 预览图生成工具命令行入口：
//   npm run generate                               读取真实 raw/ 生成全部语言预览图
//   npm run generate -- --locale zh_Hans           只生成指定语言
//   npm run generate -- --raw-dir raw-smoke        从冒烟工作区读取 raw 截图
import { relative, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.js';
import type { Config } from './config.js';
import { validateFiles } from './validate.js';
import { renderAll } from './render.js';

/** 工具根目录：src/ 的上一级，config.json、templates/、raw/、output/ 均相对它解析 */
const toolRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** 端名称对应的中文标签，用于输出摘要 */
const PLATFORM_LABELS: Record<string, string> = {
  phone: '手机',
  tablet: '平板',
  pc: '2in1',
};

/**
 * 解析命令行 --locale 参数：返回本次要生成的语言列表。
 * 支持 `--locale zh_Hans` 与 `--locale=zh_Hans` 两种形式；未指定时生成全部语言。
 */
function parseLocales(argv: string[], config: Config): string[] {
  let requested: string | undefined;
  const flagIndex = argv.indexOf('--locale');
  if (flagIndex !== -1) {
    const value = argv[flagIndex + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error('--locale 需要一个语言代码参数（如 --locale zh_Hans）');
    }
    requested = value;
  } else {
    const eqForm = argv.find((arg) => arg.startsWith('--locale='));
    if (eqForm !== undefined) {
      requested = eqForm.slice('--locale='.length);
    }
  }
  if (requested === undefined) {
    return config.locales;
  }
  if (!config.locales.includes(requested)) {
    throw new Error(`未知语言：${requested}（可用语言：${config.locales.join('、')}）`);
  }
  return [requested];
}

/**
 * 解析命令行 --raw-dir 参数：返回 raw 截图根目录（相对工具目录或绝对路径）。
 * 支持 `--raw-dir <目录>` 与 `--raw-dir=<目录>` 两种形式；未指定时缺省为真实 raw/ 目录。
 */
function parseRawDir(argv: string[]): string {
  const flagIndex = argv.indexOf('--raw-dir');
  if (flagIndex !== -1) {
    const value = argv[flagIndex + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error('--raw-dir 需要一个目录参数（如 --raw-dir raw-smoke）');
    }
    return value;
  }
  const eqForm = argv.find((arg) => arg.startsWith('--raw-dir='));
  if (eqForm !== undefined) {
    const value = eqForm.slice('--raw-dir='.length);
    if (value === '') {
      throw new Error('--raw-dir 需要一个目录参数（如 --raw-dir raw-smoke）');
    }
    return value;
  }
  return 'raw';
}

async function main(): Promise<void> {
  // 流程：解析参数 → 加载配置 → 文件校验 → 渲染 → 输出摘要；任一步失败即抛错退出
  const configPath = resolve(toolRoot, 'config.json');
  const config = loadConfig(configPath);
  const locales = parseLocales(process.argv.slice(2), config);
  const rawDir = parseRawDir(process.argv.slice(2));
  validateFiles(toolRoot, config);
  const results = await renderAll(toolRoot, rawDir, config, locales);

  console.log('预览图生成完成：');
  for (const { locale, platform, shots } of results) {
    console.log(`  [${locale} ${PLATFORM_LABELS[platform]} ${platform}] ${shots.length} 张`);
    for (const shot of shots) {
      // 无 raw 截图而退化为特性图的条目单独标注，便于发现文件名笔误导致的静默降级
      const suffix = shot.style === 'feature' ? '（无截图，特性图）' : '';
      console.log(`    ${relative(toolRoot, shot.file)}${suffix}`);
    }
  }
}

main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error(`错误：${message}`);
  process.exit(1);
});
