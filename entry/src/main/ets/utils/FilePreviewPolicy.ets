/**
 * FilePreviewPolicy.ets — 文本预览阈值与可预览性判定（纯函数模块，无 UI、无状态）
 *
 * 会话详情页与文件接收历史页共用同一套判定，避免两页口径分叉；
 * 阈值同时作为预览场景的文本读取上限，使「判定用阈值、读取仍读满旧上限」的分叉不再出现。
 */

/**
 * 文本预览阈值（字节）：文件大小超过该值时不读取内容、不提供全文预览，
 * 并在界面上明确说明「文件过大、不支持预览」。
 * 取值 128KB；若实测仍存在可感知卡顿，回退值为 64KB（见 TEXT_PREVIEW_MAX_BYTES_FALLBACK）。
 */
export const TEXT_PREVIEW_MAX_BYTES: number = 128 * 1024;

/** 阈值回退值（字节）：仅在实测 128KB 仍有可感知卡顿时下调使用。 */
export const TEXT_PREVIEW_MAX_BYTES_FALLBACK: number = 64 * 1024;

/** 预览场景的文本读取上限（字节）：与阈值同源，避免判定与读取口径分叉。 */
export const TEXT_PREVIEW_READ_MAX_BYTES: number = TEXT_PREVIEW_MAX_BYTES;

/** 文本可预览性三态结论。 */
export enum TextPreviewVerdict {
  /** 可预览：文本类 + 定位非空 + 大小未超阈值（大小不可得按可预览处理） */
  previewable = 'previewable',
  /** 超阈值不可预览：文本类 + 定位非空 + 大小超阈值 */
  overLimit = 'overLimit',
  /** 不可预览：文本类但定位为空，或该条目本身非文本类 */
  locationUnavailable = 'locationUnavailable'
}

/**
 * 可预览性判定（纯函数，无副作用）。
 *
 * @param isText 是否为文本类文件（判定经 MimeUtils.isTextFile 唯一来源）
 * @param location 文件定位串（空串表示不可定位）
 * @param sizeBytes 文件大小（字节）；0、负数或不可得一律按「可预览」处理，不因缺信息而误禁
 * @returns 三态结论（可预览 / 超阈值不可预览 / 不可预览）
 */
export function decideTextPreview(isText: boolean, location: string, sizeBytes: number): TextPreviewVerdict {
  if (!isText || location.length === 0) {
    return TextPreviewVerdict.locationUnavailable;
  }
  if (sizeBytes > TEXT_PREVIEW_MAX_BYTES) {
    return TextPreviewVerdict.overLimit;
  }
  return TextPreviewVerdict.previewable;
}

/** 「预览全文」是否可用（文本类 + 定位非空 + 未超阈值）。 */
export function isTextPreviewable(isText: boolean, location: string, sizeBytes: number): boolean {
  return decideTextPreview(isText, location, sizeBytes) === TextPreviewVerdict.previewable;
}

/** 是否需要在条目操作菜单内说明「文件过大、不支持预览」（超阈值为真）。 */
export function needsOverLimitHint(isText: boolean, location: string, sizeBytes: number): boolean {
  return decideTextPreview(isText, location, sizeBytes) === TextPreviewVerdict.overLimit;
}
