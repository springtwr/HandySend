// TransferProgressUtil：传输页进度聚合的纯函数（无 UI/native 依赖，可单元测试）。
import {
  TransferFileDescriptor,
  TransferFileProgress,
  FileProgressStatus,
  SendSessionState,
  TransferProgress,
  SendSessionStatus
} from '../model/Types';
import {
  ReceiverState,
  ReceiverStage,
  isMtaReceivingStage
} from '../model/mta/MtaProtocolModels';

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

// ── 后台通知/托盘聚合快照 ──

// 传输方向（后台通知聚合展示用）。
export enum TransferDirection {
  send = 'send',
  receive = 'receive',
  mtaSend = 'mtaSend',
  mtaReceive = 'mtaReceive',
  webDownload = 'webDownload'
}

// 单会话传输快照（聚合纯函数的输入/输出单元）。
export interface TransferSessionSnapshot {
  sessionId: string
  direction: TransferDirection
  // 对端设备名（发送方向 = 目标别名；接收方向 = 发送方别名）
  displayName: string
  bytesSent: number
  totalBytes: number
  // 是否仍在进行（数据可能流动）
  active: boolean
  // 终态成败（active 为 true 时无意义）
  success: boolean
}

// LocalSend 接收会话的原始数据（由 ReceiveRepository 快照 getter 组装，零副作用）。
// state 取 ReceiveRepository 内部状态串：'sending' | 'finished' | 'finishedWithErrors' |
// 'failed' | 'canceledBySender'；等待用户确认（'waiting'）的会话不应进入快照。
export interface ReceiveSessionData {
  sessionId: string
  senderAlias: string
  state: string
  // 各文件字节数（聚合分母）
  fileSizes: Array<number>
}

// MTA 发送会话快照原始数据（由 MtaRepository 快照 getter 组装，零副作用）。
// stage 取发送服务的阶段字符串；active/success 由 MtaTransferViewModel 映射后写入。
export interface MtaSendSnapshot {
  taskId: string
  stage: string
  sentBytes: number
  totalBytes: number
  percent: number
  active: boolean
  success: boolean
}

// Web 下载会话原始数据（由 WebShareRepository 快照 getter 组装，零副作用）。
// state 取会话内部状态串：'pending' | 'accepted' | 'finished' | 'failed'；
// 等待用户确认（'pending'）的会话不应进入聚合（后台无法确认）。
export interface WebDownloadSessionData {
  sessionId: string
  fileSizes: Array<number>
  state: string
}

// Web 下载单文件进度（由 Rust webSendProgress 事件上报后记录，按会话×文件归属）。
export interface WebDownloadProgress {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
}

// 整体聚合快照（后台通知/托盘渲染的最终输入）。
export interface OverallTransferSnapshot {
  // 是否存在进行中的会话（后台长时任务申请/保持依据）
  active: boolean
  percent: number
  bytesSent: number
  totalBytes: number
  // 进行中的会话数
  sessionCount: number
  // 进行中会话涉及的不同对端设备名数
  deviceCount: number
  // 输入非空且全部会话已终态
  allFinished: boolean
  // 任一会话以失败终态（allFinished 时用于选择成功/失败文案）
  hasFailure: boolean
}

// 发送会话状态 → 是否仍在进行（与 SendRepository.isActiveSendStatus 语义一致）
function isSendStatusActive(status: SendSessionStatus): boolean {
  return status === SendSessionStatus.waiting ||
    status === SendSessionStatus.calculatingHash ||
    status === SendSessionStatus.sending;
}

// 按 fileId 归属聚合会话已发送字节：先按 sessionId 匹配，不匹配时回退按文件归属
// （多目标逻辑会话 id multi_xxx_i 与进度事件的接收方会话 id UUID 不一致），
// 每个文件取其最大 bytesSent，避免同一文件多条进度重复计数。
// 与 computeSessionProgress 的归属逻辑保持同源。
function aggregateSessionBytesSent(sessionId: string, fileIds: Array<string>,
  activeProgress: Array<TransferProgress>): number {
  let perFileSent: Record<string, number> = {};
  for (let k = 0; k < activeProgress.length; k++) {
    let p = activeProgress[k];
    let belongs: boolean = p.sessionId === sessionId;
    if (!belongs) {
      for (let j = 0; j < fileIds.length; j++) {
        if (fileIds[j] === p.fileId) {
          belongs = true;
          break;
        }
      }
    }
    if (belongs) {
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
  return sent;
}

function clampBytes(bytes: number, total: number): number {
  if (bytes < 0) {
    return 0;
  }
  if (total > 0 && bytes > total) {
    return total;
  }
  return bytes;
}

// 发送会话列表 → 逐会话快照。
// finished 会话强制 bytesSent = totalBytes（activeProgress 清除后不归零）；
// 其余终态（finishedWithErrors/declined 等）按实际聚合字节呈现。
export function buildSendSessionSnapshots(
  sessions: Array<SendSessionState>,
  activeProgress: Array<TransferProgress>
): Array<TransferSessionSnapshot> {
  let snapshots: Array<TransferSessionSnapshot> = [];
  for (let i = 0; i < sessions.length; i++) {
    let st = sessions[i];
    let fileIds: Array<string> = [];
    let total: number = 0;
    for (let j = 0; j < st.files.length; j++) {
      fileIds.push(st.files[j].fileId);
      total = total + st.files[j].size;
    }
    let sent: number = aggregateSessionBytesSent(st.sessionId, fileIds, activeProgress);
    let active: boolean = isSendStatusActive(st.status);
    let success: boolean = st.status === SendSessionStatus.finished;
    if (success) {
      sent = total;
    }
    snapshots.push({
      sessionId: st.sessionId,
      direction: TransferDirection.send,
      displayName: st.targetAlias,
      bytesSent: clampBytes(sent, total),
      totalBytes: total,
      active: active,
      success: success
    });
  }
  return snapshots;
}

// LocalSend 接收会话 → 逐会话快照。
// 'sending' 进行中；'finished' 成功终态（字节补齐到总分母，进度条清除后不归零）；
// 其余（'finishedWithErrors'/'failed'/'canceledBySender'）失败终态，按实际字节。
export function buildReceiveSessionSnapshots(
  sessions: Array<ReceiveSessionData>,
  activeProgress: Array<TransferProgress>
): Array<TransferSessionSnapshot> {
  let snapshots: Array<TransferSessionSnapshot> = [];
  for (let i = 0; i < sessions.length; i++) {
    let data = sessions[i];
    let total: number = 0;
    for (let j = 0; j < data.fileSizes.length; j++) {
      total = total + data.fileSizes[j];
    }
    let sent: number = aggregateSessionBytesSent(data.sessionId, [], activeProgress);
    let active: boolean = data.state === 'sending';
    let success: boolean = data.state === 'finished';
    if (success) {
      sent = total;
    }
    snapshots.push({
      sessionId: data.sessionId,
      direction: TransferDirection.receive,
      displayName: data.senderAlias,
      bytesSent: clampBytes(sent, total),
      totalBytes: total,
      active: active,
      success: success
    });
  }
  return snapshots;
}

// MTA 接收 → 单会话快照。
// 空闲/服务待命/等待用户确认（request_received）返回 undefined（不进入聚合）；
// 建链/下载/落盘为进行中；COMPLETED/FAILED 为终态。
// 分母用 receiveRequest.totalSize（接收请求声明的原始总大小）而非 progress.totalBytes
// （压缩传输时 progress.totalBytes 可能为 0 或与原始大小不一致）。
export function buildMtaReceiveSessionSnapshot(state: ReceiverState): TransferSessionSnapshot | undefined {
  let request = state.receiveRequest;
  let total: number = request !== undefined ? request.totalSize : 0;
  let displayName: string = request !== undefined ? request.senderName : '';
  if (state.stage === ReceiverStage.COMPLETED || state.stage === ReceiverStage.FAILED) {
    return {
      sessionId: 'mta',
      direction: TransferDirection.mtaReceive,
      displayName: displayName,
      bytesSent: state.stage === ReceiverStage.COMPLETED ? total : clampBytes(state.progress.receivedBytes, total),
      totalBytes: total,
      active: false,
      success: state.stage === ReceiverStage.COMPLETED
    };
  }
  if (!isMtaReceivingStage(state.stage)) {
    return undefined;
  }
  return {
    sessionId: 'mta',
    direction: TransferDirection.mtaReceive,
    displayName: displayName,
    bytesSent: clampBytes(state.progress.receivedBytes, total),
    totalBytes: total,
    active: true,
    success: false
  };
}

// MTA 发送快照 → 单会话快照（active/success 由 MtaTransferViewModel 从发送状态映射后写入）；
// 无快照返回 undefined（不进入聚合）。
export function buildMtaSendSessionSnapshot(
  snapshot: MtaSendSnapshot | undefined
): TransferSessionSnapshot | undefined {
  if (snapshot === undefined) {
    return undefined;
  }
  return {
    sessionId: snapshot.taskId.length > 0 ? snapshot.taskId : 'mta_send',
    direction: TransferDirection.mtaSend,
    displayName: '',
    bytesSent: clampBytes(snapshot.sentBytes, snapshot.totalBytes),
    totalBytes: snapshot.totalBytes,
    active: snapshot.active,
    success: snapshot.success
  };
}

// Web 下载会话 → 逐会话快照。
// 'accepted'/'transferring' 进行中；'finished' 成功终态（字节补齐到总分母，清除后不归零）；
// 其余（'declined'/'failed'）失败终态，按实际聚合字节。
// 进度按「会话×文件」归属（sessionId + fileId），同一文件重复/并发下载互不串扰。
export function buildWebDownloadSessionSnapshots(
  sessions: Array<WebDownloadSessionData>,
  progress: Array<WebDownloadProgress>
): Array<TransferSessionSnapshot> {
  let snapshots: Array<TransferSessionSnapshot> = [];
  for (let i = 0; i < sessions.length; i++) {
    let data = sessions[i];
    let total: number = 0;
    for (let j = 0; j < data.fileSizes.length; j++) {
      total = total + data.fileSizes[j];
    }
    let perFileSent: Record<string, number> = {};
    for (let k = 0; k < progress.length; k++) {
      let p = progress[k];
      if (p.sessionId !== data.sessionId) {
        continue;
      }
      let prev: number | undefined = perFileSent[p.fileId];
      if (prev === undefined || p.bytesSent > prev) {
        perFileSent[p.fileId] = p.bytesSent;
      }
    }
    let sent: number = 0;
    let fids = Object.keys(perFileSent);
    for (let k = 0; k < fids.length; k++) {
      sent = sent + perFileSent[fids[k]];
    }
    let active: boolean = data.state === 'accepted' || data.state === 'transferring';
    let success: boolean = data.state === 'finished';
    if (success) {
      sent = total;
    }
    snapshots.push({
      sessionId: data.sessionId,
      direction: TransferDirection.webDownload,
      // 对端设备名：网页下载以客户端标识（IP）作为展示名
      displayName: data.sessionId,
      bytesSent: clampBytes(sent, total),
      totalBytes: total,
      active: active,
      success: success
    });
  }
  return snapshots;
}

// 整体聚合：进度/字节/会话数/设备数只统计进行中会话；allFinished/hasFailure
// 统计全部输入（终态会话在转为终态后短暂存留，供终态通知判定成败）。
// prevPercent 为上次展示值，传入时进度单调不减（会话退出/清理导致分母骤变时防回跳）。
export function computeOverallTransferSnapshot(
  sessions: Array<TransferSessionSnapshot>,
  prevPercent: number = 0
): OverallTransferSnapshot {
  let activeSessions: Array<TransferSessionSnapshot> = [];
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i].active) {
      activeSessions.push(sessions[i]);
    }
  }
  let bytesSent: number = 0;
  let totalBytes: number = 0;
  let deviceNames: Array<string> = [];
  for (let i = 0; i < activeSessions.length; i++) {
    bytesSent = bytesSent + activeSessions[i].bytesSent;
    totalBytes = totalBytes + activeSessions[i].totalBytes;
    let name: string = activeSessions[i].displayName;
    if (name.length > 0 && deviceNames.indexOf(name) < 0) {
      deviceNames.push(name);
    }
  }
  let percent: number = 0;
  if (activeSessions.length > 0) {
    if (totalBytes > 0) {
      percent = (bytesSent * 100) / totalBytes;
      if (percent > 100) {
        percent = 100;
      }
    }
  } else if (sessions.length > 0) {
    // 全部终态：按全部输入的字节聚合出最终进度
    for (let i = 0; i < sessions.length; i++) {
      bytesSent = bytesSent + sessions[i].bytesSent;
      totalBytes = totalBytes + sessions[i].totalBytes;
    }
    if (totalBytes > 0) {
      percent = (bytesSent * 100) / totalBytes;
      if (percent > 100) {
        percent = 100;
      }
    }
  }
  if (percent < prevPercent) {
    percent = prevPercent;
  }
  let hasFailure: boolean = false;
  for (let i = 0; i < sessions.length; i++) {
    if (!sessions[i].active && !sessions[i].success) {
      hasFailure = true;
      break;
    }
  }
  return {
    active: activeSessions.length > 0,
    percent: percent,
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    sessionCount: activeSessions.length,
    deviceCount: deviceNames.length,
    allFinished: sessions.length > 0 && activeSessions.length === 0,
    hasFailure: hasFailure
  };
}
