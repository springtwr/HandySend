import { statSync } from 'node:fs';
import { resolve } from 'node:path';
import { platformNames } from './config.js';
import type { Config } from './config.js';
import { ICONS } from './icons.js';

/**
 * 校验文件存在且为普通文件，缺失时抛出含绝对路径与配置位置的错误。
 * 所有校验在渲染前一次性完成，保证失败时不产出任何结果文件。
 */
function requireFile(absPath: string, configLocation: string): void {
  let isFile = false;
  try {
    isFile = statSync(absPath).isFile();
  } catch {
    isFile = false;
  }
  if (!isFile) {
    throw new Error(`文件缺失：${absPath}（引用位置：${configLocation}）`);
  }
}

/**
 * 渲染前一次性校验配置引用的固定文件：共享样式、三端模板、设备框素材，
 * 以及特性图标名。任一缺失即抛错，错误信息包含缺失文件的绝对路径。
 * raw 截图不在校验范围：缺失时对应预览图自动退化为文字特性图（见 render.ts）。
 */
export function validateFiles(toolRoot: string, config: Config): void {
  // 共享样式被三个模板引用，缺失会导致页面无样式静默出错，需前置检查
  requireFile(resolve(toolRoot, 'templates', 'shared.css'), 'templates/shared.css（模板共享样式）');

  // 图标名必须在图标集中定义，缺失时列出全部可用名便于修正
  for (const [id, feature] of Object.entries(config.features)) {
    if (feature.icon !== undefined && !(feature.icon in ICONS)) {
      throw new Error(
        `未知图标名：${feature.icon}（features.${id}.icon；可用图标：${Object.keys(ICONS).join('、')}）`,
      );
    }
  }

  for (const platform of platformNames()) {
    const platformConfig = config.platforms[platform];
    requireFile(
      resolve(toolRoot, 'templates', `${platform}.html`),
      `templates/${platform}.html（${platform} 端模板）`,
    );
    requireFile(
      resolve(toolRoot, platformConfig.frame.image),
      `platforms.${platform}.frame.image`,
    );
  }
}
