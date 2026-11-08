/**
 * TransferTempPaths.ets — 接收落盘临时区的路径规则
 *
 * 与 Rust 侧 `bridge/temp_workspace.rs` 的 `.handysend-temp/` 规则保持一致：
 * 未完成文件写在最终文件同父目录的应用独占隐藏子目录中，完成后 rename 到最终路径。
 * 旧名 `.handysend-upload-part` 作为 legacy 目录做 best-effort 清理。
 */

export const TEMP_DIR_NAME: string = '.handysend-temp';

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

/** 最终路径对应的临时目录。 */
export function tempDirForFinal(finalPath: string): string {
  let dir: string = dirNameOf(finalPath);
  if (dir.length === 0) {
    return TEMP_DIR_NAME;
  }
  return dir + '/' + TEMP_DIR_NAME;
}

/** 最终路径对应的临时文件路径。 */
export function tempPathForFinal(finalPath: string): string {
  return tempDirForFinal(finalPath) + '/' + baseNameOf(finalPath);
}
