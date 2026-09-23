/**
 * DemoData.ets — 演示数据与进度节奏常量（仅演示分支存在）
 *
 * 收/发两组多文件清单（演示命名 + GB/MB 级元数据，与实际落盘占位文件解耦）、
 * 两条中文演示文本、四场景枚举与推进节奏。
 * 进度节奏：1s tick 推进约 60MB，总量 3.6GB 约 60s 完成，
 * 速度由既有 UI 的字节增量/时间口径自然计算（显示 ≥ 50MB/s），演示代码不干预。
 */

/** 占位文件生成方式 */
export enum DemoFileKind {
  /** 小 PNG 占位图片（真实可解码，供历史缩略图渲染） */
  image = 'image',
  /** 文本内容文件 */
  text = 'text',
  /** 通用小体积占位（内容为演示说明文本） */
  generic = 'generic'
}

/** 演示文件条目元数据 */
export interface DemoFileSpec {
  /** 文件标识（会话内唯一） */
  fileId: string
  /** 演示文件名 */
  fileName: string
  /** MIME 类型 */
  fileType: string
  /** 元数据大小（字节，与占位文件实际大小解耦） */
  sizeBytes: number
  /** 占位文件生成方式 */
  demoKind: DemoFileKind
}

/** 四类演示场景 */
export enum DemoScenarioType {
  /** 模拟收到文件请求（待确认 → 确认 → 进行中 → 成功） */
  receiveFiles = 'receiveFiles',
  /** 模拟收到文本消息（待确认 → 接受 → 成功） */
  receiveText = 'receiveText',
  /** 模拟发出文件传输（直接进行中 → 成功） */
  sendFiles = 'sendFiles',
  /** 模拟发出文本消息（短暂进行中 → 成功） */
  sendText = 'sendText'
}

/** 推进节奏 */
export interface DemoProgressPlan {
  /** 推进间隔（毫秒） */
  tickIntervalMs: number
  /** 每次推进的字节数 */
  bytesPerTick: number
}

/** 收文件演示清单（5 条，总量 3,600,000,000 字节） */
export const DEMO_RECEIVE_FILES: Array<DemoFileSpec> = [
  {
    fileId: 'demo-recv-0',
    fileName: '周末露营视频.mp4',
    fileType: 'video/mp4',
    sizeBytes: 1536000000,
    demoKind: DemoFileKind.generic
  },
  {
    fileId: 'demo-recv-1',
    fileName: '家庭相册精选.zip',
    fileType: 'application/zip',
    sizeBytes: 1180000000,
    demoKind: DemoFileKind.generic
  },
  {
    fileId: 'demo-recv-2',
    fileName: '生日聚会录像.mp4',
    fileType: 'video/mp4',
    sizeBytes: 620000000,
    demoKind: DemoFileKind.generic
  },
  {
    fileId: 'demo-recv-3',
    fileName: '旅行合照.png',
    fileType: 'image/png',
    sizeBytes: 8400000,
    demoKind: DemoFileKind.image
  },
  {
    fileId: 'demo-recv-4',
    fileName: '年会照片包.zip',
    fileType: 'application/zip',
    sizeBytes: 255600000,
    demoKind: DemoFileKind.generic
  }
];

/** 发文件演示清单（4 条，总量 3,600,000,000 字节） */
export const DEMO_SEND_FILES: Array<DemoFileSpec> = [
  {
    fileId: 'demo-send-0',
    fileName: '产品发布会视频.mp4',
    fileType: 'video/mp4',
    sizeBytes: 2050000000,
    demoKind: DemoFileKind.generic
  },
  {
    fileId: 'demo-send-1',
    fileName: '设计源文件打包.zip',
    fileType: 'application/zip',
    sizeBytes: 1120000000,
    demoKind: DemoFileKind.generic
  },
  {
    fileId: 'demo-send-2',
    fileName: '团建合影.png',
    fileType: 'image/png',
    sizeBytes: 96000000,
    demoKind: DemoFileKind.image
  },
  {
    fileId: 'demo-send-3',
    fileName: '项目交付物.7z',
    fileType: 'application/x-7z-compressed',
    sizeBytes: 334000000,
    demoKind: DemoFileKind.generic
  }
];

/** 收文本演示文案 */
export const DEMO_RECEIVE_TEXT: string =
  '周六下午三点在老地方见，别忘了带上上次说的那本书，到时给你介绍新来的同事。';

/** 发文本演示文案 */
export const DEMO_SEND_TEXT: string =
  '这周的会议纪要和附件都在这里了，有空看一下，有问题随时找我。';

/** 文本演示文件名（落盘与历史展示共用） */
export const DEMO_TEXT_FILE_NAME: string = '演示文本.txt';

/** 文件场景推进节奏：1s tick、每次 60,000,000 字节（60MB/s） */
export const DEMO_PROGRESS_PLAN: DemoProgressPlan = {
  tickIntervalMs: 1000,
  bytesPerTick: 60000000
};

/** 文本发送场景的短暂进行中时长（毫秒）：随后即成功收尾 */
export const DEMO_TEXT_SEND_DURATION_MS: number = 1500;

/** 待确认续期间隔（毫秒）：小于既有 60s 待确认超时，保证截图期间画面不消失 */
export const DEMO_PENDING_RENEW_INTERVAL_MS: number = 45000;
