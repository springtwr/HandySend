/**
 * UserStoragePaths.ets — 公共用户存储路径（跨模块唯一来源）
 *
 * 文件选择器与系统文件管理器统一使用 `file://docs/storage/...` 形式，
 * 需要起始目录的场景（接收目录、发送页“下载”入口）从这里取，避免各模块硬编码前缀。
 */

/** 用户根目录 URI（文件管理器视角，末尾带斜杠）。 */
export const DOC_USER_ROOT_URI: string = 'file://docs/storage/Users/currentUser/';

/** 存储根目录 URI（末尾带斜杠）。 */
export const DOC_STORAGE_ROOT_URI: string = 'file://docs/storage/';

/** 用户 Download 目录 URI（末尾不带斜杠，可直接作为选择器起始目录）。 */
export const USER_DOWNLOAD_URI: string = DOC_USER_ROOT_URI + 'Download';
