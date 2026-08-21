// @ts-nocheck – HarmonyOS template file, only used when copied into a DevEco project
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

/**
 * 检测依赖是否已安装（oh_modules 符号链接是否存在）。
 * 首次 clone 后需要 ohpm install 创建符号链接，否则编译失败。
 */
function isDepsInstalled(projectRoot: string): boolean {
  const entryDep = path.join(projectRoot, 'entry', 'oh_modules', 'localsend_ohrs');
  return fs.existsSync(entryDep);
}

/**
 * 在 hvigor 配置阶段自动执行 ohpm install。
 * 不注册为 task，因为依赖安装必须在任何模块构建之前完成，
 * 而 hvigor task 系统在配置阶段后才执行，时机太晚。
 */
function ensureDepsInstalled(projectRoot: string): void {
  if (isDepsInstalled(projectRoot)) {
    return;
  }
  console.log('[OhpmInstall] Dependencies not installed, running ohpm install...');
  const result = spawnSync('ohpm', ['install'], {
    cwd: projectRoot,
    stdio: 'inherit',
    timeout: 120000,
  });
  if (result.error) {
    throw new Error(`ohpm install failed: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`ohpm install failed with exit code ${result.status}`);
  }
  console.log('[OhpmInstall] Dependencies installed successfully.');
}

// 在模块加载时立即执行，确保后续所有 task 都能找到依赖
ensureDepsInstalled(process.cwd());

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []
}
