/**
 * TransferTempPaths.ets — 接收落盘临时区的路径规则
 *
 * 与 Rust 侧 `bridge/temp_workspace.rs` 的 `.handysend-temp/` 规则保持一致：
 * 未完成文件写在最终文件同父目录的应用独占隐藏目录中，完成后 rename 到最终路径。
 * 临时区按协议分子目录，避免不同协议的同名文件互相截断；临时文件存在即表示
 * 该最终文件名已被占用。旧名 `.handysend-upload-part` 与旧协议子目录名
 * `local-send` 作为 legacy 目录清理。
 */

export const TEMP_DIR_NAME: string = '.handysend-temp';

/** 各接收协议的临时子目录名。 */
export const TEMP_SUBDIR_LOCAL_SEND: string = 'localsend';
export const TEMP_SUBDIR_MTA: string = 'mta';
export const TEMP_SUBDIR_WEB: string = 'web';
export const TEMP_SUBDIRS: Array<string> =
  [TEMP_SUBDIR_LOCAL_SEND, TEMP_SUBDIR_MTA, TEMP_SUBDIR_WEB];

/** 旧版本协议子目录名：只用于清理升级前遗留的临时文件。 */
export const LEGACY_TEMP_SUBDIRS: Array<string> = ['local-send'];

export const LEGACY_TEMP_DIR_NAMES: Array<string> = ['.handysend-upload-part'];

/** 返回最终路径的父目录；无分隔符时返回空串。 */
export function dirNameOf(path: string): string {
  let index: number = path.lastIndexOf('/');
  return index >= 0 ? path.substring(0, index) : '';
}

/** 返回最终路径的文件名；无分隔符时返回原串。 */
export function baseNameOf(path: string): string {
  let index: number = path.lastIndexOf('/');
  return index >= 0 ? path.substring(index + 1) : path;
}

/** 最终路径对应的临时区根目录。 */
export function tempRootForFinal(finalPath: string): string {
  let dir: string = dirNameOf(finalPath);
  if (dir.length === 0) {
    return TEMP_DIR_NAME;
  }
  return dir + '/' + TEMP_DIR_NAME;
}

/** 最终路径在指定协议子目录下的临时目录。 */
export function tempDirForFinal(finalPath: string, subdir: string): string {
  return tempRootForFinal(finalPath) + '/' + subdir;
}

/** 最终路径在指定协议子目录下的临时文件路径。 */
export function tempPathForFinal(finalPath: string, subdir: string): string {
  return tempDirForFinal(finalPath, subdir) + '/' + baseNameOf(finalPath);
}

/** 目录名是否为当前或旧版本的协议临时子目录。 */
export function isProtocolTempSubdir(name: string): boolean {
  return TEMP_SUBDIRS.indexOf(name) >= 0 || LEGACY_TEMP_SUBDIRS.indexOf(name) >= 0;
}

/** 最终路径在所有协议临时子目录下的候选临时路径（用于恢复时兜底清理）。 */
export function tempPathsForFinal(finalPath: string): Array<string> {
  let result: Array<string> = [];
  for (let i = 0; i < TEMP_SUBDIRS.length; i++) {
    result.push(tempPathForFinal(finalPath, TEMP_SUBDIRS[i]));
  }
  return result;
}
