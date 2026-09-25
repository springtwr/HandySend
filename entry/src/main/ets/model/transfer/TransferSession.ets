/**
 * TransferSession.ets — 统一会话领域模型
 *
 * 统一会话建模「用户可见的一次有界传输活动」，与协议层会话/授权解耦：
 * - 协议层会话由适配器内部管理（可能长期授权、可能无结束信号、可能时序上 1:N）；
 * - 注册表只持有统一会话，并负责终态后的可见窗口、归档与回收；
 * - 传输模型由两个正交维度描述：数据流向（outbound/inbound）与发起方（local/remote）。
 */

// ── 枚举 ──

/** 统一生命周期状态。协议特有阶段必须映射到该集合。 */
export enum SessionStage {
  awaitingConfirmation = 'awaitingConfirmation',
  active = 'active',
  succeeded = 'succeeded',
  partiallyFailed = 'partiallyFailed',
  failed = 'failed',
  cancelled = 'cancelled',
  declined = 'declined'
}

/** 数据流向：本机为数据源（outbound）或本机为接收方（inbound）。 */
export enum SessionDataFlow {
  outbound = 'outbound',
  inbound = 'inbound'
}

/** 发起方：本机发起（local）或对端发起（remote）。 */
export enum SessionInitiator {
  local = 'local',
  remote = 'remote'
}

/** 任务历史记录的结果。 */
export enum SessionHistoryOutcome {
  succeeded = 'succeeded',
  partiallyFailed = 'partiallyFailed',
  failed = 'failed',
  cancelled = 'cancelled',
  declined = 'declined'
}

/** 单文件传输阶段。 */
export enum SessionFileStage {
  waiting = 'waiting',
  transferring = 'transferring',
  completed = 'completed',
  failed = 'failed',
  // 已取消：会话被取消时，未完成（等待中/传输中）文件置为该终态；已完成/已失败文件不变
  cancelled = 'cancelled'
}

/** 详情页时间线事件类别。 */
export enum SessionEventKind {
  created = 'created',
  confirmed = 'confirmed',
  started = 'started',
  completed = 'completed',
  failed = 'failed',
  cancelled = 'cancelled',
  declined = 'declined'
}

// ── 值对象 ──

/** 对端标识（可为匿名，仅有 IP）。 */
export interface SessionPeer {
  displayName: string
  ip?: string
  fingerprint?: string
  // 对端设备类型（缺失/未知时展示层回退手机图标）
  deviceType?: string
  // MTA 来源品牌标识：存在即表示对端为互传（MTA）来源，值决定设备卡品牌图标；
  // -1 表示未知品牌（回退默认 MTA 图标）；非 MTA 来源不设置（undefined）
  mtaBrandId?: number
  // 对端在接收确认阶段提供的预览图本地路径（目前仅 MTA 缩略图；缺失表示无预览）
  previewImagePath?: string
  badges: Array<string>
}

/** 会话能力声明：驱动动作区与统一取消分发。 */
export interface SessionCapabilities {
  canCancel: boolean
  canRetry: boolean
  needsConfirm: boolean
  hasByteProgress: boolean
  canSaveToGallery: boolean
  hasVerify: boolean
}

/** 关键事件时间线（事件携带统一会话标识，供后续按会话检索诊断）。 */
export interface SessionTimelineEvent {
  kind: SessionEventKind
  timestamp: number
  detail?: string
  sessionId: string
}

/** 协议无关的整体聚合快照（后台长时任务与通知消费）。 */
export interface OverallSnapshot {
  active: boolean
  percent: number
  bytesSent: number
  totalBytes: number
  sessionCount: number
  deviceCount: number
  allFinished: boolean
  hasFailure: boolean
}

/** 任务筛选条件（字段缺省表示不筛）。 */
export interface SessionFilter {
  stage?: SessionStage
  protocolKey?: string
  dataFlow?: SessionDataFlow
}

/** 创建会话时的文件描述（分母可后续增长）。 */
export interface SessionFileDescriptor {
  fileId: string
  fileName: string
  fileType: string
  totalBytes: number
  occurrence?: number
  // 校验和/哈希（协议或链路提供时携带，未提供为空）
  checksum?: string
  // 该文件在磁盘上的位置（可选）：用于按路径读取文本内容预览；
  // 接收侧由接收目标解析结果写入，发送侧由发送条目写入；缺省表示不可预览
  path?: string
}

/** 创建会话的输入描述。 */
export interface SessionCreateInput {
  protocolKey: string
  protocolSessionId: string
  dataFlow: SessionDataFlow
  initiatedBy: SessionInitiator
  peer: SessionPeer
  files: Array<SessionFileDescriptor>
  capabilities: SessionCapabilities
  stage?: SessionStage
  stageText?: ResourceStr
}

/**
 * 适配器提供的展示描述符：通用详情页/中心条目所需的协议差异展示信息。
 * 外壳不含任何协议分支，差异仅经描述符、能力声明与可选插槽表达。
 * 对端名称/副标题与方向文案以 ResourceStr 承载，随系统语言切换。
 */
export interface SessionDisplayDescriptor {
  // 对端标题：对端名称非空时为原字符串，缺失时为本地化兜底文案
  peerTitle: ResourceStr
  // 对端副标题：通常为对端 IP，缺失时为空
  peerSubtitle: ResourceStr
  badges: Array<string>
  // 对端设备类型（驱动详情页设备图标；缺失/未知时为 'mobile'）
  deviceType: string
  // MTA 来源品牌标识：存在即表示对端为互传（MTA）来源（-1 为未知品牌，回退默认 MTA 图标）；
  // 非 MTA 来源不设置（undefined），设备卡据此选择设备类型图标
  mtaBrandId?: number
  directionLabel: ResourceStr
  supportsTextPreview: boolean
  textPreview?: string
}

// ── 可变实体 ──

/** 会话内的单个文件（@Trace 字段支持列表行内刷新）。 */
@ObservedV2
export class SessionFile {
  fileId: string = ''
  fileName: string = ''
  fileType: string = ''
  totalBytes: number = 0
  // 同一文件在一次会话内的第几次出现（Web 下载同 IP 多次下载由 burst 会话规避，通常为 1）
  occurrence: number = 1
  // 校验和/哈希（协议或链路提供时记录，未提供为空串）
  checksum: string = ''
  // 该文件在磁盘上的位置（空串表示不可预览）：用于按路径读取文本内容
  path: string = ''
  @Trace bytesSent: number = 0
  @Trace stage: SessionFileStage = SessionFileStage.waiting
}

/** 一次用户可见的有界传输活动。 */
@ObservedV2
export class TransferSession {
  // 统一会话标识（由适配器生成，含来源前缀）
  id: string = ''
  protocolKey: string = ''
  // 适配器侧协议标识（供适配器维护映射，进度归属不依赖文件标识回退匹配）
  protocolSessionId: string = ''
  dataFlow: SessionDataFlow = SessionDataFlow.outbound
  initiatedBy: SessionInitiator = SessionInitiator.local
  @Trace stage: SessionStage = SessionStage.active
  peer: SessionPeer = emptyPeer()
  @Trace files: Array<SessionFile> = []
  @Trace bytesSent: number = 0
  @Trace totalBytes: number = 0
  // 离散阶段口径的文案（无字节进度的协议使用；以资源承载以便随语言切换）
  @Trace stageText: ResourceStr = ''
  @Trace errorMessage: string = ''
  // 协议/链路错误码（无法取得时为空串）
  @Trace errorCode: string = ''
  // 本机设备标识（昵称 / 默认 IP / 网卡接口名）：创建会话时采集，写入历史以支撑详情展示
  localAlias: string = ''
  localIp: string = ''
  localInterfaceName: string = ''
  // 传输性能指标（不可得时为 0）
  @Trace averageSpeedBps: number = 0
  @Trace peakSpeedBps: number = 0
  startedAt: number = 0
  @Trace finishedAt: number = 0
  capabilities: SessionCapabilities = defaultCapabilities()
  @Trace timeline: Array<SessionTimelineEvent> = []
}

// ── 纯逻辑辅助 ──

/** 是否终态。 */
export function isTerminalStage(stage: SessionStage): boolean {
  return stage === SessionStage.succeeded || stage === SessionStage.partiallyFailed ||
    stage === SessionStage.failed || stage === SessionStage.cancelled ||
    stage === SessionStage.declined;
}

/** 是否成功类终态（用于聚合成败汇总）。 */
export function isSuccessStage(stage: SessionStage): boolean {
  return stage === SessionStage.succeeded;
}

/** 统一状态 → 历史结果（非终态返回 undefined）。 */
export function outcomeForStage(stage: SessionStage): SessionHistoryOutcome | undefined {
  if (stage === SessionStage.succeeded) {
    return SessionHistoryOutcome.succeeded;
  }
  if (stage === SessionStage.partiallyFailed) {
    return SessionHistoryOutcome.partiallyFailed;
  }
  if (stage === SessionStage.failed) {
    return SessionHistoryOutcome.failed;
  }
  if (stage === SessionStage.cancelled) {
    return SessionHistoryOutcome.cancelled;
  }
  if (stage === SessionStage.declined) {
    return SessionHistoryOutcome.declined;
  }
  return undefined;
}

/** 默认能力声明（不支持任何动作）。 */
export function defaultCapabilities(): SessionCapabilities {
  return {
    canCancel: false,
    canRetry: false,
    needsConfirm: false,
    hasByteProgress: true,
    canSaveToGallery: false,
    hasVerify: false
  };
}

/** 空对端（匿名）。 */
export function emptyPeer(): SessionPeer {
  return { displayName: '', badges: [] };
}

/** 会话动作可用性：任务列表行与会话详情页共用的统一动作口径。 */
export interface SessionActionAvailability {
  canConfirm: boolean
  canDecline: boolean
  canCancel: boolean
}

/**
 * 解析会话可用动作（纯函数，统一动作口径的唯一事实源）：
 * - 待确认且适配器声明需确认：可确认、可拒绝（文本消息会话沿用同一判定，仅按钮标签不同）；
 * - 非终态且适配器声明可取消：可取消（该规则天然覆盖发送任务「等待对端接收/确认」阶段）。
 * 可用性与是否文本消息无关，按钮标签由调用方自行选择。
 */
export function resolveSessionActions(stage: SessionStage,
  capabilities: SessionCapabilities): SessionActionAvailability {
  let awaiting: boolean = stage === SessionStage.awaitingConfirmation && capabilities.needsConfirm;
  return {
    canConfirm: awaiting,
    canDecline: awaiting,
    canCancel: !isTerminalStage(stage) && capabilities.canCancel
  };
}
