// 读取输出 PNG 的 IHDR 宽高，与 config.json 中各端 outputSize 逐一比对。
// 按 语言 × 端 × 条目 遍历约定输出路径：output/<端>/<语言>/<特性>.png。
// 不引入图像库依赖：PNG 的宽高固定存储在文件第 16–24 字节（IHDR 数据块）。
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const toolRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(readFileSync(resolve(toolRoot, 'config.json'), 'utf8'));

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** 解析 PNG 宽高，非有效 PNG 文件时抛错 */
function readPngSize(buf) {
  if (buf.length < 24 || !buf.subarray(0, 8).equals(PNG_SIGNATURE)) {
    throw new Error('不是有效的 PNG 文件');
  }
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

let failed = false;
for (const [platform, platformConfig] of Object.entries(config.platforms)) {
  for (const locale of config.locales) {
    for (const featureId of config.shots) {
      const file = resolve(toolRoot, 'output', platform, locale, `${featureId}.png`);
      let actual;
      try {
        actual = readPngSize(readFileSync(file));
      } catch {
        console.error(`✗ [${platform}/${locale}] 缺少输出文件：${file}`);
        failed = true;
        continue;
      }
      const expected = platformConfig.outputSize;
      const ok = actual.width === expected.width && actual.height === expected.height;
      console.log(
        `${ok ? '✓' : '✗'} [${platform}/${locale}] ${featureId}.png ` +
          `${actual.width}×${actual.height}（期望 ${expected.width}×${expected.height}）`,
      );
      if (!ok) {
        failed = true;
      }
    }
  }
}

if (failed) {
  console.error('尺寸校验未通过');
  process.exit(1);
}
console.log('全部输出尺寸校验通过');
