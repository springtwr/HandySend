// 两类历史保留容量的唯一事实源：修改任一上限只需改动本文件，
// 各自的裁剪实现与测试均引用此处常量（不使用散落在实现处的字面量）。
//
// 两个上限的计数单位不同且不可互换：任务历史按「会话」计数，文件接收历史按「文件」计数。
// 一次传输产生 1 条任务历史，却产生 N 条文件接收历史（N 为该次传输的文件数），
// 故两个上限数值相同并不代表保留的时间跨度相同——任务历史覆盖「上限」次传输，
// 接收历史只覆盖「上限 ÷ N」次传输。两个上限独立生效，不做相互换算。
// 100 文件批量传输会同时放大两者：任务历史单条约 35-43KB，接收历史一次新增 100 条。

/**
 * 任务历史裁剪目标（软上限），单位：会话。
 * 750 = 250 × 3，须为 SESSION_HISTORY_SEGMENT_SIZE 的整数倍。
 * 未超过硬上限时保留全部条目，使追加只写末段；超过硬上限时一次性裁回本值，
 * 把全量重写摊薄到约 250 次追加一次。100 文件批次下裁剪写入最坏约 32MB。
 */
export const SESSION_HISTORY_CAPACITY: number = 750;

/**
 * 任务历史硬上限，单位：会话。
 * 1000 = 250 × 4。达到本值后才触发裁剪，避免每追加一条就整体左移并重写全部段。
 */
export const SESSION_HISTORY_MAX_ENTRIES: number = 1000;

/**
 * 文件接收历史保留条数上限（有界 FIFO，最旧优先裁剪），单位：文件。
 * 5000 = 250 × 20，须为 RECEIVE_HISTORY_SEGMENT_SIZE 的整数倍。
 * 单条约 0.3KB，5000 条约 1.6MB；100 文件批次下覆盖约 50 次传输。
 */
export const RECEIVE_HISTORY_CAPACITY: number = 5000;

// ── 分段存储 ──
//
// 偏好存储只提供「按键整体覆写」这一种更新集合的方式，故单键方案的每次写入都要
// 序列化全量历史，代价随保留条数线性增长——上限抬高后会直接变成主线程开销。
// 分段把集合切成若干段分别存放，未超过硬上限时新增条目只写当前活跃段，代价与总量解耦。
//
// 段大小按两类历史各自的条目体积校准，不再共用：
// - 任务历史单条常见 2-6KB，250 条约 0.5-1.5MB；100 文件批次单条约 35-43KB，
//   满段约 10.5MB，已接近 Preferences 单值 16MB 上限；目标容量 750，硬上限 1000 用于批量裁剪。
// - 接收历史单条约 0.3KB，250 条约 80KB；5000 条约 1.6MB。
//
// 段数 = 目标容量 ÷ 段大小；硬上限允许额外一段，用于批量裁剪。
// 目标容量与硬上限都须为段大小的整数倍，否则裁剪会从段中间切，
// 导致每次追加都整体左移并重写全部段。

/** 任务历史分段的段大小（单段最多容纳的条目数）。 */
export const SESSION_HISTORY_SEGMENT_SIZE: number = 250;

/** 任务历史目标容量对应的段数；容量 = 段大小 × 段数。 */
export const SESSION_HISTORY_SEGMENT_COUNT: number = 3;

/** 任务历史硬上限对应的段数；多出的一段用于在裁剪前承接新增条目。 */
export const SESSION_HISTORY_MAX_SEGMENT_COUNT: number = 4;

/** 旧布局的段数：两类历史升级前均为 250 条 × 8 段。 */
const HISTORY_LEGACY_SEGMENT_COUNT: number = 8;

/**
 * 任务历史读取/清理时探测的段数上限：取硬上限段数与旧布局段数的较大值。
 * 必须覆盖升级前已存在的旧段，否则降低容量后只探测 0-2 会把最新的 3-7 段读丢；
 * 升容量时也无需手工同步该常量。
 */
export const SESSION_HISTORY_STORAGE_SEGMENT_COUNT: number =
  SESSION_HISTORY_MAX_SEGMENT_COUNT > HISTORY_LEGACY_SEGMENT_COUNT ?
    SESSION_HISTORY_MAX_SEGMENT_COUNT : HISTORY_LEGACY_SEGMENT_COUNT;

/** 文件接收历史分段的段大小。 */
export const RECEIVE_HISTORY_SEGMENT_SIZE: number = 250;

/** 文件接收历史分段段数；容量 = 段大小 × 段数。 */
export const RECEIVE_HISTORY_SEGMENT_COUNT: number = 20;

/**
 * 文件接收历史读取/清理时探测的段数上限：取当前段数与旧布局段数的较大值。
 * 升容量是加法（旧段 0-7 仍有效）；降容量时也能读到 3-7 段，不因当前段数变小而丢数据。
 */
export const RECEIVE_HISTORY_STORAGE_SEGMENT_COUNT: number =
  RECEIVE_HISTORY_SEGMENT_COUNT > HISTORY_LEGACY_SEGMENT_COUNT ?
    RECEIVE_HISTORY_SEGMENT_COUNT : HISTORY_LEGACY_SEGMENT_COUNT;
