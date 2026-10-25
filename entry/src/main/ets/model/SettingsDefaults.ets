// 设置默认值唯一事实来源：全部设置项默认值的集中定义。
// 修改任一设置项的默认值只需改动本文件，Repository 初始值/回退值、
// ViewModel 字段初始值、恢复默认逻辑、视图层默认值判断均引用此处常量。
// 对应的持久化 KEY 定义位于 utils/PreferencesUtil.ets（KEY 是持久化契约，
// 默认值是产品决策，两者变更原因不同，分属两文件）。

import { AutoConfirmMode } from './Types';
import { MTA_BRAND_ID_THIRD_PARTY } from './mta/MtaBrandRegistry';

// ── 加密 / HTTPS ──
export const DEFAULT_ENCRYPTED_TRANSFER: boolean = true;

// ── 接收设置 ──
export const DEFAULT_AUTO_CONFIRM_MODE: AutoConfirmMode = AutoConfirmMode.off;

export const DEFAULT_RECEIVE_PIN: string = '';

export const DEFAULT_AUTO_FINISH: boolean = true;


export const DEFAULT_SAVE_TO_GALLERY: boolean = false;

export const DEFAULT_DESTINATION: string = '';

// ── 主题 / 语言 / 外观 ──
export const DEFAULT_THEME: string = 'system';

// 语言：空串表示跟随系统
export const DEFAULT_LOCALE: string = '';

export const DEFAULT_HIDE_TAB_BAR_ON_SCROLL: boolean = false;

// ── 设备身份 ──
// 空字符串时根据系统信息自动检测
export const DEFAULT_CUSTOM_ALIAS: string = '';

// ── 校验和设置 ──
export const DEFAULT_CREATE_CHECKSUMS: boolean = false;

export const DEFAULT_VERIFY_CHECKSUMS: boolean = false;

// ── 发送设置 ──
export const DEFAULT_AUTO_CLEAR_STAGED: boolean = false;

// ── 高级 / 网络设置 ──
export const DEFAULT_ADVANCED_SETTINGS: boolean = false;

export const DEFAULT_PORT: number = 53317;

export const DEFAULT_MULTICAST_GROUP: string = '224.0.0.167';

export const DEFAULT_DISCOVERY_TIMEOUT: number = 1000;

// 网络白/黑名单：空串仅指无持久化时的初始态，
// 首次启动的动态默认内容见 SettingsRepository.ensureDefaultNetworkLists
export const DEFAULT_NETWORK_WHITELIST: string = '';

export const DEFAULT_NETWORK_BLACKLIST: string = '';

// ── 协议总开关 ──
export const DEFAULT_LOCALSEND_ENABLED: boolean = true;

// ── 互传联盟（MTA）──
export const DEFAULT_MTA_ENABLED: boolean = true;

// ── 网页分享 ──
export const DEFAULT_WEB_SEND_ENABLED: boolean = false;

export const DEFAULT_WEB_RECEIVE_ENABLED: boolean = false;

// 网页独立安全项：新装默认关闭/空；升级时由 SettingsRepository 一次性迁移
export const DEFAULT_WEB_HTTPS_ENABLED: boolean = false;

export const DEFAULT_WEB_PIN: string = '';

// 网页端口：53310-53316 预留给 HandySend 网页/扩展服务，避开 53317（LocalSend）
// 与 53318（localsnd CLI 的默认 HTTP 端口）
export const DEFAULT_WEB_PORT: number = 53310;

// 进程内记录的实际端口：启动成功后写入，重启服务时优先复用；不持久化，
// 应用重启后仍先尝试配置端口，避免上次回退的临时端口被带到下次启动
export const DEFAULT_WEB_LAST_PORT: number = 0;

// 空串表示白名单/黑名单为空；接口是否启用按 NetworkInterfaceRules 的类型默认规则，
// 黑名单优先，其次白名单，两者都未列出时 Wi-Fi/有线/VPN 启用
export const DEFAULT_WEB_INTERFACES: string = '';

export const DEFAULT_WEB_INTERFACE_BLACKLIST: string = '';

export const DEFAULT_WEB_DISPLAY_ADDRESS: string = '';

export const WEB_PORT_MIN: number = 1024;

export const WEB_PORT_MAX: number = 65535;


export const DEFAULT_MTA_RECEIVE_ENABLED: boolean = true;

// 默认第三方：品牌标识语义归属品牌注册表，此处仅引用
export const DEFAULT_MTA_SIMULATED_BRAND: number = MTA_BRAND_ID_THIRD_PARTY;

export const DEFAULT_MTA_CONNECTION_WARNINGS: boolean = true;
