/**
 * HistorySegments.ets — 历史分段存储的纯逻辑（键布局、段划分、裁剪计划、变更区间）
 *
 * 偏好存储只提供「按键整体覆写」，单键方案每次写入都要序列化全量历史。
 * 分段把集合切成若干段分键存放，使写入只覆盖当前活跃段，代价与总量解耦。
 *
 * 键布局契约（换存储层时按此契约实现读取即可）：
 * - 段键为 `<前缀>#<段号>`，段号自 0 起**连续**，且**递增表示更新**（0 最老，最大号最新）；
 * - 只丢弃最旧段、不单独删除中间段，故段号始终连续，无需额外索引键；
 * - 读取自 0 起向最大段号拼接（最旧在前）；裁剪从 0 起整段丢弃。
 */

import { HISTORY_SEGMENT_SIZE } from './HistoryCapacity';

/** 第 segIndex 段的键名。 */
export function segmentKey(prefix: string, segIndex: number): string {
  return prefix + '#' + segIndex;
}

/**
 * 探测已存在的段号列表（自 0 起连续，遇缺即止）。
 * 调用方须先确保段号连续（写入路径只追加最大段号、裁剪只丢最旧段）。
 */
export function existingSegments(prefix: string, has: (key: string) => boolean,
  maxSegments: number): Array<number> {
  let found: Array<number> = [];
  for (let i = 0; i < maxSegments; i++) {
    if (!has(segmentKey(prefix, i))) {
      break;
    }
    found.push(i);
  }
  return found;
}

/**
 * 段划分：条目按顺序切分为若干段，最旧的段在前（段号 0 最老，递增表示更新）。
 * 末段可不足段大小——追加到末段满时才开新段。
 */
export function splitIntoSegments<T>(entries: Array<T>, segmentSize: number): Array<Array<T>> {
  let segments: Array<Array<T>> = [];
  if (segmentSize <= 0 || entries.length === 0) {
    return segments;
  }
  let current: Array<T> = [];
  for (let i = 0; i < entries.length; i++) {
    current.push(entries[i]);
    if (current.length >= segmentSize) {
      segments.push(current);
      current = [];
    }
  }
  if (current.length > 0) {
    segments.push(current);
  }
  return segments;
}

/**
 * 裁剪计划：按「保留最近 capacity 条」丢弃最旧的整段，返回裁剪后应落盘的段序列。
 * 容量为段大小的整数倍，故裁剪只丢弃整段即可精确命中，无需段内裁剪。
 */
export function planSegments<T>(entries: Array<T>, capacity: number,
  segmentSize: number): Array<Array<T>> {
  let kept: Array<T> = entries;
  if (capacity > 0 && kept.length > capacity) {
    kept = kept.slice(kept.length - capacity);
  }
  return splitIntoSegments(kept, segmentSize);
}

/**
 * 变更区间：找出两份条目集合中内容不同的下标范围，闭区间。
 * 用于只重写受影响的段——追加只命中末段，删除/替换可能横跨多段。
 * 无差异时返回 undefined。
 */
export function dirtyRange<T>(oldEntries: Array<T>, newEntries: Array<T>): DirtyRange | undefined {
  let shared: number = oldEntries.length < newEntries.length ? oldEntries.length : newEntries.length;
  let firstDiff: number = -1;
  for (let i = 0; i < shared; i++) {
    if (oldEntries[i] !== newEntries[i]) {
      firstDiff = i;
      break;
    }
  }
  // 短的序列已全部匹配：差异只可能出现在较长序列的尾部
  if (firstDiff < 0) {
    if (oldEntries.length === newEntries.length) {
      return undefined;
    }
    firstDiff = shared;
  }
  // 区间右端从新集合尾部向前收敛；清空场景下新集合为空，
  // 受影响的是旧集合整体，故右端取旧集合末尾
  let lastDiff: number = newEntries.length - 1;
  if (lastDiff < firstDiff) {
    lastDiff = oldEntries.length - 1;
  } else {
    while (lastDiff > firstDiff && oldEntries[lastDiff] === newEntries[lastDiff]) {
      lastDiff--;
    }
  }
  return { first: firstDiff, last: lastDiff };
}

/** 变更区间的闭区间下标。 */
export interface DirtyRange {
  first: number
  last: number
}

/** 变更区间覆盖的段号（段号自 0 起对应最旧段，递增表示更新）。 */
export function segmentsOfDirtyRange(range: DirtyRange, segmentSize: number): Array<number> {
  let segments: Array<number> = [];
  if (segmentSize <= 0) {
    return segments;
  }
  let firstSegment: number = Math.floor(range.first / segmentSize);
  let lastSegment: number = Math.floor(range.last / segmentSize);
  for (let i = firstSegment; i <= lastSegment; i++) {
    segments.push(i);
  }
  return segments;
}
