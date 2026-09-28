/**
 * DemoTaskData.ets — 演示任务中心模拟任务清单（仅演示分支存在）
 *
 * 固定 12 条终态任务记录的事实来源：覆盖 LocalSend（5）/ 互传 MTA（4）/ web（3）
 * 三种来源，成功 7 / 部分失败 1 / 失败 2 / 取消 2 多种结果，含 2 条文本任务。
 * 纯数据无副作用；由 DemoTaskHistory 解析为历史条目并幂等注入历史存储。
 */

import {
  SessionDataFlow,
  SessionHistoryOutcome,
  SessionInitiator
} from '../../model/transfer/TransferSession';

/** 模拟任务来源（用于清单组织与对端解析分派） */
export enum DemoTaskSource {
  localsend = 'localsend',
  mta = 'mta',
  web = 'web'
}

/**
 * 文件清单来源：
 * - receive：收方向多文件清单（DEMO_RECEIVE_FILES）
 * - send：发方向多文件清单（DEMO_SEND_FILES）
 * - text：单条文本文件条目
 * - mtaAggregate：互传接收的单聚合条目（对齐真实 MTA 单条目接收会话）
 */
export enum DemoTaskFileSource {
  receive = 'receive',
  send = 'send',
  text = 'text',
  mtaAggregate = 'mtaAggregate'
}

/** 模拟任务清单条目（纯数据） */
export interface DemoTaskSpec {
  /** 固定统一会话标识（前缀 demo-task-），幂等键 */
  sessionId: string
  /** 来源：localsend / mta / web */
  source: DemoTaskSource
  /** 协议键：localsend-send / localsend-receive / mta-send / mta-receive / web-download */
  protocolKey: string
  /** 数据流向 */
  dataFlow: SessionDataFlow
  /** 发起方 */
  initiatedBy: SessionInitiator
  /** 对端引用：本地/互传为虚拟设备昵称；web 为固定 web 对端键 */
  peerRef: string
  /** 是否文本任务（决定单条文本文件与可预览落盘） */
  isText: boolean
  /** 文件清单来源 */
  fileSource: DemoTaskFileSource
  /** 结果 */
  outcome: SessionHistoryOutcome
  /** 成功完成的文件条数（失败/取消的混合文件阶段用） */
  completedCount: number
  /** 部分失败的失败文件下标（-1 表示无；仅 partiallyFailed 使用） */
  failedIndex: number
  /** 失败错误文案（非失败为空串） */
  errorMessage: string
  /** 失败错误码（非失败为空串） */
  errorCode: string
  /** 相对基准的起始偏移（毫秒，越大越早），决定列表顺序 */
  startOffsetMs: number
  /** 会话耗时（毫秒） */
  durationMs: number
  /** 平均速度（字节/秒） */
  averageSpeedBps: number
  /** 峰值速度（字节/秒） */
  peakSpeedBps: number
}

/** 固定 web 对端（浏览器客户端）身份：以客户端 IP 作对端名，与真实 web 会话口径一致 */
export interface DemoWebPeer {
  /** 客户端 IP（同时用作对端显示名） */
  ip: string
}

/** 固定 web 对端键（清单 peerRef 取值） */
export const DEMO_WEB_PEER_KEY: string = 'web-client';

/** 固定 web 对端身份常量 */
export const DEMO_WEB_PEER: DemoWebPeer = {
  ip: '192.168.31.203'
};

/** 模拟任务统一会话标识前缀（幂等注入的固定键前缀） */
export const DEMO_TASK_SESSION_PREFIX: string = 'demo-task-';

// 时间偏移基准换算
const DEMO_MINUTE_MS: number = 60 * 1000;
const DEMO_HOUR_MS: number = 60 * DEMO_MINUTE_MS;

/** 固定模拟任务清单（12 条：LocalSend 5 / 互传 4 / web 3，含文本 2 条） */
export const DEMO_TASK_CATALOG: Array<DemoTaskSpec> = [
  // ── LocalSend（5 条） ──
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'ls1',
    source: DemoTaskSource.localsend,
    protocolKey: 'localsend-send',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerRef: '张三',
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 35 * DEMO_MINUTE_MS,
    durationMs: 62000,
    averageSpeedBps: 58000000,
    peakSpeedBps: 78000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'ls2',
    source: DemoTaskSource.localsend,
    protocolKey: 'localsend-receive',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: 'Kat',
    isText: false,
    fileSource: DemoTaskFileSource.receive,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 7 * DEMO_HOUR_MS,
    durationMs: 74000,
    averageSpeedBps: 48600000,
    peakSpeedBps: 66500000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'ls3',
    source: DemoTaskSource.localsend,
    protocolKey: 'localsend-receive',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: '张三',
    isText: true,
    fileSource: DemoTaskFileSource.text,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 4 * DEMO_HOUR_MS,
    durationMs: 1500,
    averageSpeedBps: 0,
    peakSpeedBps: 0
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'ls4',
    source: DemoTaskSource.localsend,
    protocolKey: 'localsend-send',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerRef: 'Kat',
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.failed,
    completedCount: 2,
    failedIndex: -1,
    errorMessage: '对端拒绝接收或连接中断',
    errorCode: 'send_failed',
    startOffsetMs: 30 * DEMO_HOUR_MS,
    durationMs: 41000,
    averageSpeedBps: 21000000,
    peakSpeedBps: 52000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'ls5',
    source: DemoTaskSource.localsend,
    protocolKey: 'localsend-send',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerRef: '张三',
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.cancelled,
    completedCount: 1,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 74 * DEMO_HOUR_MS,
    durationMs: 18000,
    averageSpeedBps: 12000000,
    peakSpeedBps: 40000000
  },
  { // ── 互传 MTA（4 条） ──
    sessionId: DEMO_TASK_SESSION_PREFIX + 'mta1',
    source: DemoTaskSource.mta,
    protocolKey: 'mta-send',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerRef: 'Leo',
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 150 * DEMO_MINUTE_MS,
    durationMs: 68000,
    averageSpeedBps: 53000000,
    peakSpeedBps: 72000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'mta2',
    source: DemoTaskSource.mta,
    protocolKey: 'mta-receive',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: '张三',
    isText: false,
    fileSource: DemoTaskFileSource.mtaAggregate,
    outcome: SessionHistoryOutcome.partiallyFailed,
    completedCount: 0,
    failedIndex: 0,
    errorMessage: '部分文件传输失败',
    errorCode: 'partial_failed',
    startOffsetMs: 50 * DEMO_HOUR_MS,
    durationMs: 39000,
    averageSpeedBps: 18000000,
    peakSpeedBps: 45000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'mta3',
    source: DemoTaskSource.mta,
    protocolKey: 'mta-send',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerRef: 'Leo',
    isText: true,
    fileSource: DemoTaskFileSource.text,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 26 * DEMO_HOUR_MS,
    durationMs: 1600,
    averageSpeedBps: 0,
    peakSpeedBps: 0
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'mta4',
    source: DemoTaskSource.mta,
    protocolKey: 'mta-receive',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: '张三',
    isText: false,
    fileSource: DemoTaskFileSource.mtaAggregate,
    outcome: SessionHistoryOutcome.cancelled,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 96 * DEMO_HOUR_MS,
    durationMs: 22000,
    averageSpeedBps: 9000000,
    peakSpeedBps: 30000000
  },
  { // ── web（3 条：浏览器上传收文件 + 网页下载成功/失败） ──
    sessionId: DEMO_TASK_SESSION_PREFIX + 'web1',
    source: DemoTaskSource.web,
    protocolKey: 'localsend-receive',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: DEMO_WEB_PEER_KEY,
    isText: false,
    fileSource: DemoTaskFileSource.receive,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 6 * DEMO_HOUR_MS,
    durationMs: 83000,
    averageSpeedBps: 43400000,
    peakSpeedBps: 61000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'web2',
    source: DemoTaskSource.web,
    protocolKey: 'web-download',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: DEMO_WEB_PEER_KEY,
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.succeeded,
    completedCount: 0,
    failedIndex: -1,
    errorMessage: '',
    errorCode: '',
    startOffsetMs: 90 * DEMO_MINUTE_MS,
    durationMs: 55000,
    averageSpeedBps: 65000000,
    peakSpeedBps: 82000000
  },
  {
    sessionId: DEMO_TASK_SESSION_PREFIX + 'web3',
    source: DemoTaskSource.web,
    protocolKey: 'web-download',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.remote,
    peerRef: DEMO_WEB_PEER_KEY,
    isText: false,
    fileSource: DemoTaskFileSource.send,
    outcome: SessionHistoryOutcome.failed,
    completedCount: 1,
    failedIndex: -1,
    errorMessage: '下载过程中网络连接中断',
    errorCode: 'web_download_failed',
    startOffsetMs: 53 * DEMO_HOUR_MS,
    durationMs: 27000,
    averageSpeedBps: 24000000,
    peakSpeedBps: 58000000
  }
];

