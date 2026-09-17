// TransferProgressUtil：传输页进度聚合的纯函数（无 UI/native 依赖，可单元测试）。
import {
  TransferFileDescriptor,
  TransferFileProgress,
  FileProgressStatus,
  SendSessionState,
  TransferProgress,
  SendSessionStatus
} from '../model/Types';

// 依据 fileInfos 与 sentByFileId（key=fileId）计算每文件进度。
// 分母用各文件的 fileInfo.size；字节数取 sentByFileId，保证已完成文件在
// activeProgress 移除后不丢贡献；状态按字节数判定。
// 传入 existing 时按 fileId 复用实例（原地更新 @Trace 进度字段），
// 使 UI 只做行内刷新而整行不重建；新增文件自动新建实例。
export function computeTransferFileProgress(
  fileInfos: Array<TransferFileDescriptor>,
  sentByFileId: Record<string, number>,
  existing?: Array<TransferFileProgress>
): Array<TransferFileProgress> {
  let reusable: Map<string, TransferFileProgress> = new Map();
  if (existing !== undefined) {
    for (let i = 0; i < existing.length; i++) {
      reusable.set(existing[i].fileId, existing[i]);
    }
  }
  let list: Array<TransferFileProgress> = [];
  for (let i = 0; i < fileInfos.length; i++) {
    let info = fileInfos[i];
    let sent: number = 0;
    let existingSent: number | undefined = sentByFileId[info.fileId];
    if (existingSent !== undefined) {
      sent = existingSent;
    }
    let pct: number = info.size > 0 ? (sent * 100) / info.size : 0;
    if (pct > 100) {
      pct = 100;
    }
    let status: FileProgressStatus = FileProgressStatus.waiting;
    if (info.size > 0 && sent >= info.size) {
      status = FileProgressStatus.completed;
    } else if (sent > 0) {
      status = FileProgressStatus.transferring;
    } else {
      status = FileProgressStatus.waiting;
    }
    let prev = reusable.get(info.fileId);
    if (prev !== undefined) {
      // 复用实例：仅更新可变进度字段（@Trace 驱动行内刷新）
      prev.bytesSent = sent;
      prev.percent = pct;
      prev.status = status;
      list.push(prev);
    } else {
      let fp = new TransferFileProgress();
      fp.fileId = info.fileId;
      fp.fileName = info.fileName;
      fp.size = info.size;
      fp.fileType = info.fileType;
      fp.bytesSent = sent;
      fp.percent = pct;
      fp.status = status;
      list.push(fp);
    }
  }
  return list;
}

// 依据发送会话列表与 activeProgress 聚合每会话（sessionId）的发送百分比。
// 仅 finished（成功）终态强制按 100% 呈现，避免 activeProgress 清除后归零（文本消息等
// 无进度事件的成功场景依赖此兜底）；其余状态（含 finishedWithErrors）按实际聚合字节
// 计算，未开始传输即失败（如协议不匹配被拒绝）显示 0%。
// 多目标模式下逻辑会话 id（multi_xxx_i）与进度事件的接收方会话 id（UUID）不一致，
// 因此按"会话内文件(fileId) 的进度"聚合（每个文件取其最大 bytesSent），保证进度条随传输移动。
export function computeSessionProgress(
  sessions: Array<SendSessionState>,
  activeProgress: Array<TransferProgress>
): Record<string, number> {
  let progress: Record<string, number> = {};
  for (let i = 0; i < sessions.length; i++) {
    let st = sessions[i];
    let total: number = 0;
    for (let j = 0; j < st.files.length; j++) {
      total = total + st.files[j].size;
    }
    // 每个文件取其最大已发送字节（不重复计数）
    let perFileSent: Record<string, number> = {};
    for (let k = 0; k < activeProgress.length; k++) {
      let p = activeProgress[k];
      let inSession: boolean = p.sessionId === st.sessionId;
      if (!inSession) {
        // 回退：按文件归属匹配（多目标逻辑会话 id 与接收方会话 id 不一致）
        for (let j = 0; j < st.files.length; j++) {
          if (st.files[j].fileId === p.fileId) {
            inSession = true;
            break;
          }
        }
      }
      if (inSession) {
        let prev: number | undefined = perFileSent[p.fileId];
        if (prev === undefined || p.bytesSent > prev) {
          perFileSent[p.fileId] = p.bytesSent;
        }
      }
    }
    let sent: number = 0;
    let fids = Object.keys(perFileSent);
    for (let k = 0; k < fids.length; k++) {
      sent = sent + perFileSent[fids[k]];
    }
    let pct: number = 0;
    if (st.status === SendSessionStatus.finished) {
      pct = 100;
    } else if (total > 0) {
      pct = (sent * 100) / total;
      if (pct > 100) {
        pct = 100;
      }
    }
    progress[st.sessionId] = pct;
  }
  return progress;
}
