import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';

// 拖入的文本条目：content 为纯文本原文或超链接「描述+URL」组合内容，
// isLink 标记是否来自超链接记录（仅用于可追溯日志，不影响暂存行为）
export interface DroppedTextItem {
  content: string;
  isLink: boolean;
}

// 拖入内容解析结果：uris 为文件类记录提取的 URI 列表（去重由 stageUris 承担），
// texts 为文本类记录提取的内容列表
export interface DragDropParseResult {
  uris: Array<string>;
  texts: Array<DroppedTextItem>;
}

// 文件类 UTD 判定：general.file/general.image/general.video/general.audio
function isFileType(type: string): boolean {
  return type === uniformTypeDescriptor.UniformDataType.FILE ||
    type === uniformTypeDescriptor.UniformDataType.IMAGE ||
    type === uniformTypeDescriptor.UniformDataType.VIDEO ||
    type === uniformTypeDescriptor.UniformDataType.AUDIO;
}

// 提取文件类记录的文件 URI。
// Image/Video/Audio 继承 File，但各自维护独立的 uri 属性（imageUri/videoUri/audioUri），
// 官方写入侧只设置子类属性、基类 uri 保持为空，故按 UTD 类型分别读取子类属性；
// 子类属性为空或读取异常（记录实际非该子类）时回退基类 File.uri，保证不中断整批解析。
function extractFileUri(record: unifiedDataChannel.UnifiedRecord, type: string): string {
  if (type === uniformTypeDescriptor.UniformDataType.IMAGE) {
    try {
      let image: unifiedDataChannel.Image = record as unifiedDataChannel.Image;
      let imageUri: string = image.imageUri;
      if (imageUri.length > 0) {
        return imageUri;
      }
    } catch (_e) {
    }
  } else if (type === uniformTypeDescriptor.UniformDataType.VIDEO) {
    try {
      let video: unifiedDataChannel.Video = record as unifiedDataChannel.Video;
      let videoUri: string = video.videoUri;
      if (videoUri.length > 0) {
        return videoUri;
      }
    } catch (_e) {
    }
  } else if (type === uniformTypeDescriptor.UniformDataType.AUDIO) {
    try {
      let audio: unifiedDataChannel.Audio = record as unifiedDataChannel.Audio;
      let audioUri: string = audio.audioUri;
      if (audioUri.length > 0) {
        return audioUri;
      }
    } catch (_e) {
    }
  }
  let file: unifiedDataChannel.File = record as unifiedDataChannel.File;
  return file.uri;
}

// 纯函数：UDMF 拖拽记录 → 可暂存内容分流（禁止 I/O 与副作用，空数组返回空结果）。
// 文件类读 uri 入 uris；general.plain-text 读 textContent 入 texts(isLink=false)；
// general.hyperlink 按「描述+URL」组合规则入 texts(isLink=true)；
// 其余类型（含 general.folder、openharmony.app-item 等）暂不支持，静默跳过。
export function parseDroppedRecords(records: Array<unifiedDataChannel.UnifiedRecord>): DragDropParseResult {
  let result: DragDropParseResult = { uris: [], texts: [] };
  for (let i = 0; i < records.length; i++) {
    let record: unifiedDataChannel.UnifiedRecord = records[i];
    let type: string = record.getType();
    if (isFileType(type)) {
      let uri: string = '';
      try {
        uri = extractFileUri(record, type);
      } catch (_e) {
        uri = '';
      }
      if (uri.length > 0) {
        result.uris.push(uri);
      }
    } else if (type === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
      let textRecord = record as unifiedDataChannel.PlainText;
      let content: string = textRecord.textContent;
      if (content.length > 0) {
        result.texts.push({ content: content, isLink: false });
      }
    } else if (type === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
      // UDMF 的 Hyperlink 记录字段为 url（链接地址）与 description（链接描述），
      // 语义对应分享链路中的「链接地址 + 标题」；组合规则与既有 hyperlink 分享保持一致：
      // 均非空 → 描述+'\n'+URL；仅其一非空 → 用其值；均空 → 跳过
      let linkRecord = record as unifiedDataChannel.Hyperlink;
      // description 为可选字段，缺失时按空描述处理（仅用 URL 作为内容）
      let title: string = linkRecord.description ?? '';
      let linkUrl: string = linkRecord.url;
      let content: string = '';
      if (title.length > 0 && linkUrl.length > 0) {
        content = title + '\n' + linkUrl;
      } else if (linkUrl.length > 0) {
        content = linkUrl;
      } else if (title.length > 0) {
        content = title;
      }
      if (content.length > 0) {
        result.texts.push({ content: content, isLink: true });
      }
    }
    // 其余类型跳过（Folder 等不支持类型不进入结果）
  }
  return result;
}

// 单次尝试获取拖入的 UDMF 数据：getData() 成功且记录非空时回调数据并返回 true。
// 大数据量拖拽场景数据经 UDMF 传递存在时延或抛异常，统一按失败处理交由调用方决定重试。
function tryFetchDroppedOnce(
  dragEvent: DragEvent,
  onResult: (data: unifiedDataChannel.UnifiedData | undefined) => void
): boolean {
  try {
    let data: unifiedDataChannel.UnifiedData = dragEvent.getData();
    if (!data) {
      return false;
    }
    let records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
    if (records.length === 0) {
      return false;
    }
    onResult(data);
    return true;
  } catch (_e) {
    return false;
  }
}

// 获取拖入的 UDMF 数据：首次 getData() 失败或记录为空时延迟 1500ms 重试一次（官方建议），
// 重试仍失败回调 undefined，由调用方据此执行 setResult(DRAG_FAILED)。
export function fetchDroppedUnifiedData(
  dragEvent: DragEvent,
  onResult: (data: unifiedDataChannel.UnifiedData | undefined) => void
): void {
  if (tryFetchDroppedOnce(dragEvent, onResult)) {
    return;
  }
  setTimeout(() => {
    // 重试仍失败时显式回调 undefined：调用方据此复位拖拽高亮并反馈失败，
    // 否则 onResult 永不被调用，拖入高亮态会一直残留
    if (!tryFetchDroppedOnce(dragEvent, onResult)) {
      onResult(undefined);
    }
  }, 1500);
}
