/**
 * DemoReceiveHistory.ets — 演示文件接收历史种子注入（仅演示分支存在）
 *
 * 应用启动时（initDemoModule）把固定清单写入既有接收历史存储，
 * 使接收历史页冷启动即有内容，无需先触发模拟场景。
 * 条目使用固定 id：已存在即跳过，重启不重复；清除接收历史后重启按清单重建。
 * 占位文件复用落盘目录，同名文件已存在时不重复写入。
 */

import { util } from '@kit.ArkTS';
import { ReceiveHistoryEntry } from '../../model/Types';
import { addEntries, getHistory } from '../repository/ReceiveHistoryService';
import { ensureDemoFile } from './DemoFileWriter';
import { DemoFileKind, DEMO_RECEIVE_TEXT } from './DemoData';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:DemoReceiveHistory', '演示接收历史');

// 文本消息演示文件名（独立于任务历史的演示文本文件名，避免同名占位文件复用造成内容串用）
const DEMO_RECEIVE_TEXT_FILE_NAME: string = '周末安排.txt';

// 时间偏移基准换算
const DEMO_MINUTE_MS: number = 60 * 1000;
const DEMO_HOUR_MS: number = 60 * DEMO_MINUTE_MS;

// 非文本条目的占位文件内容（真实文件不可用，仅供落盘与「用其他应用打开」走通）
const PLACEHOLDER_CONTENT: string = 'HandySend 演示占位文件：实际内容以接收元数据为准。';

/** 演示接收历史清单条目（纯数据） */
interface DemoReceiveHistorySpec {
  /** 固定条目标识，幂等键 */
  id: string
  fileName: string
  fileType: string
  /** 元数据大小（字节；文本消息按文本 UTF-8 字节数覆盖） */
  sizeBytes: number
  senderAlias: string
  /** 相对基准的接收偏移（毫秒，越大越早） */
  offsetMs: number
  /** 占位文件生成方式 */
  kind: DemoFileKind
  /** 是否为文本消息（单条文本、携带正文文件） */
  isMessage: boolean
  /** 文本消息正文（非文本条目为空串） */
  textContent: string
}

/**
 * 固定接收历史清单（8 条，最旧在前）：覆盖图片 / 视频 / 表格 / 文本消息 /
 * 压缩包 / 音频等类型，发送者对端覆盖新增演示设备。
 */
const DEMO_RECEIVE_HISTORY: Array<DemoReceiveHistorySpec> = [
  {
    id: 'demo-recv-hist-01',
    fileName: '现场录音.m4a',
    fileType: 'audio/mp4',
    sizeBytes: 18600000,
    senderAlias: '李四',
    offsetMs: 74 * DEMO_HOUR_MS,
    kind: DemoFileKind.generic,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-02',
    fileName: '产品白皮书.pdf',
    fileType: 'application/pdf',
    sizeBytes: 4800000,
    senderAlias: '张三',
    offsetMs: 52 * DEMO_HOUR_MS,
    kind: DemoFileKind.generic,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-03',
    fileName: '团建合影.png',
    fileType: 'image/png',
    sizeBytes: 5600000,
    senderAlias: 'Ethan',
    offsetMs: 26 * DEMO_HOUR_MS,
    kind: DemoFileKind.image,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-04',
    fileName: '项目资料.zip',
    fileType: 'application/zip',
    sizeBytes: 320000000,
    senderAlias: 'HomeNAS',
    offsetMs: 9 * DEMO_HOUR_MS,
    kind: DemoFileKind.generic,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-05',
    fileName: DEMO_RECEIVE_TEXT_FILE_NAME,
    fileType: 'text/plain',
    sizeBytes: 0,
    senderAlias: '李四',
    offsetMs: 7 * DEMO_HOUR_MS,
    kind: DemoFileKind.text,
    isMessage: true,
    textContent: DEMO_RECEIVE_TEXT
  },
  {
    id: 'demo-recv-hist-06',
    fileName: '报价单.xlsx',
    fileType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    sizeBytes: 1200000,
    senderAlias: 'Kat',
    offsetMs: 5 * DEMO_HOUR_MS,
    kind: DemoFileKind.generic,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-07',
    fileName: '会议录屏.mp4',
    fileType: 'video/mp4',
    sizeBytes: 268000000,
    senderAlias: 'Mia',
    offsetMs: 2 * DEMO_HOUR_MS,
    kind: DemoFileKind.generic,
    isMessage: false,
    textContent: ''
  },
  {
    id: 'demo-recv-hist-08',
    fileName: '旅行合照.png',
    fileType: 'image/png',
    sizeBytes: 8400000,
    senderAlias: '王五',
    offsetMs: 30 * DEMO_MINUTE_MS,
    kind: DemoFileKind.image,
    isMessage: false,
    textContent: ''
  }
];

/**
 * 幂等注入演示接收历史：按固定 id 跳过已存在条目，缺失条目一次性批量写入。
 * 清除接收历史后固定 id 不再命中，下一次启动即重建（与任务历史种子同口径）。
 */
export function seedDemoReceiveHistory(): void {
  let existing: Set<string> = new Set();
  let current: Array<ReceiveHistoryEntry> = getHistory();
  for (let i = 0; i < current.length; i++) {
    existing.add(current[i].id);
  }
  let base: number = Date.now();
  let batch: Array<ReceiveHistoryEntry> = [];
  for (let i = 0; i < DEMO_RECEIVE_HISTORY.length; i++) {
    let spec: DemoReceiveHistorySpec = DEMO_RECEIVE_HISTORY[i];
    if (existing.has(spec.id)) {
      continue;
    }
    let content: string = spec.isMessage ? spec.textContent : PLACEHOLDER_CONTENT;
    let path: string = ensureDemoFile(spec.fileName, spec.kind, content);
    let entry: ReceiveHistoryEntry = {
      id: spec.id,
      fileName: spec.fileName,
      fileType: spec.fileType,
      path: path,
      savedToGallery: false,
      isMessage: spec.isMessage,
      // 文本消息按正文实际字节数记录，与真实接收口径一致
      fileSize: spec.isMessage ? utf8ByteLength(spec.textContent) : spec.sizeBytes,
      senderAlias: spec.senderAlias,
      timestamp: base - spec.offsetMs
    };
    batch.push(entry);
  }
  if (batch.length === 0) {
    return;
  }
  addEntries(batch);
  logger.info('演示接收历史已注入 条数=' + batch.length);
}

/** 文本 UTF-8 字节数 */
function utf8ByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).length;
}
