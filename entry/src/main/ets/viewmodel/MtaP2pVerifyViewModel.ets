/**
 * MtaP2pVerifyViewModel.ets — MTA P2P 验证页视图模型
 *
 * 持有验证页面全部状态（建组表单/群组信息/直连表单/网络快照/HTTP 服务/
 * 日志流）与命令方法，负责调用 P2pVerifyService 并将每步操作与 API
 * 返回值写入带时间戳的日志流（上限 1000 条）。
 */

import {
  P2pVerifyService,
  P2pEventHandlers
} from '../service/mta/P2pVerifyService';
import {
  P2pGroupInfoView,
  NetworkSnapshot,
  VerifyLogEntry,
  HttpServerState,
  P2pConnectConfigView,
  NetworkListEntry,
  TcpProbeResult,
  P2pDiscoveredDeviceView,
  PRESET_STANDARD,
  PRESET_PERSISTENT,
  PRESET_MTA_CREDENTIAL,
  buildPresetConfig,
  presetKindText,
  isMacAddressText,
  generateRandomGroupName,
  generateRandomPassphrase,
  formatTimeText
} from '../model/mta/P2pVerifyModels';
import { common } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaP2pVerifyVM');

/** 日志流上限，超出丢弃最旧 */
const MAX_LOG_ENTRIES = 1000;

/** 频段选择：0 AUTO / 1 2.4G / 2 5G（对应 GroupOwnerBand） */
export const GO_BAND_AUTO = 0;
export const GO_BAND_2GHZ = 1;
export const GO_BAND_5GHZ = 2;

@ObservedV2
export class MtaP2pVerifyViewModel {
  // ── 建组状态 ──
  @Trace public groupNameInput: string = ''
  @Trace public passphraseInput: string = ''
  @Trace public selectedGoBand: number = GO_BAND_AUTO
  @Trace public groupInfo: P2pGroupInfoView | null = null
  @Trace public isGroupOperationBusy: boolean = false

  // ── 凭据直连 ──
  @Trace public credentialSsidInput: string = ''
  @Trace public credentialPskInput: string = ''
  @Trace public withUserAction: boolean = false
  @Trace public credentialResult: string = ''

  // ── 网络快照 ──
  @Trace public networkSnapshot: NetworkSnapshot | null = null
  // p2pConnectionChange 事件回调中的真实 GO IP（getP2pLinkedInfo 在普通应用下返回全零）
  @Trace public eventGroupOwnerAddr: string = ''

  // ── HTTP 服务 ──
  @Trace public httpServerState: HttpServerState = new HttpServerState()
  @Trace public httpUrlInput: string = ''
  @Trace public httpRequestResult: string = ''

  // ── p2pConnect 实验 ──
  @Trace public p2pDeviceAddressInput: string = ''
  /** 设备地址类型：0=RANDOM / 1=REAL（默认真实，P2pInfo.mac 为真实 p2p0 MAC） */
  @Trace public p2pAddressTypeIndex: number = 1
  @Trace public p2pNetIdInput: string = '-2'
  @Trace public p2pPassphraseInput: string = ''
  @Trace public p2pGroupNameInput: string = ''
  @Trace public p2pGoBandIndex: number = GO_BAND_AUTO
  @Trace public p2pConnectResult: string = ''

  // ── 网络列表快照 ──
  @Trace public networkList: Array<NetworkListEntry> = []

  // ── TCP 探测 ──
  @Trace public probeIpInput: string = '192.168.49.1'
  @Trace public probePortInput: string = '8080'
  @Trace public probeResult: TcpProbeResult | null = null
  @Trace public isProbeBusy: boolean = false

  // ── P2P 设备发现 ──
  @Trace public discoveredDevices: Array<P2pDiscoveredDeviceView> = []
  @Trace public isDiscovering: boolean = false

  // ── 日志流 ──
  @Trace public logs: Array<VerifyLogEntry> = []

  private service: P2pVerifyService = new P2pVerifyService();
  private handlers: P2pEventHandlers = new P2pEventHandlers();
  /** 应用上下文（页面 aboutToAppear 注入，供定位权限申请使用） */
  private appContext: common.Context | undefined = undefined
  /** 上次发现列表数量（用于避免重复日志刷屏） */
  private lastDiscoveredCount: number = -1

  // ── 生命周期 ──

  /** 注入应用上下文（页面 aboutToAppear 调用，供权限申请与 BLE 接收使用） */
  injectContext(context: common.Context | undefined): void {
    this.appContext = context;
  }

  /** 页面 aboutToAppear：注册事件并记录初始状态 */
  loadInitial(): void {
    this.bindHandlers();
    this.service.registerP2pEvents(this.handlers);
    this.service.registerDiscoveryEvents((devices: Array<P2pDiscoveredDeviceView>) => {
      this.discoveredDevices = devices;
      // 数量变化才记日志，避免发现事件高频刷屏
      if (devices.length !== this.lastDiscoveredCount) {
        this.lastDiscoveredCount = devices.length;
        this.appendLog('设备发现', `发现列表更新，共 ${devices.length} 台`, 'info');
      }
    });
    this.refreshNames();
    this.appendLog('初始化', '验证页面就绪，事件已注册', 'info');
    this.refreshNetwork();
  }

  /** 页面 aboutToDisappear：反注册事件并执行资源清理 */
  destroy(): void {
    this.service.unregisterP2pEvents();
    this.service.unregisterDiscoveryEvents();
    this.cleanupAll();
  }

  // ── 事件绑定 ──

  private bindHandlers(): void {
    this.handlers.onP2pConnectionChange = (summary: string): void => {
      this.appendLog('p2pConnectionChange', summary, 'info');
      // 连接状态变化时顺带刷新网络快照
      this.refreshNetwork();
      // 建组/连接是异步生效的，事件到达才是准确信号，此时刷新群组信息
      this.onQueryGroup();
    };
    this.handlers.onP2pStateChange = (state: string): void => {
      this.appendLog('p2pStateChange', state, 'info');
    };
    this.handlers.onWifiConnectionChange = (state: string): void => {
      this.appendLog('wifiConnectionChange', state, 'info');
      this.refreshNetwork();
    };
    this.handlers.onRawP2pConnection = (raw: string): void => {
      this.appendLog('p2pConnectionChange 原始数据', raw, 'info');
      // 事件回调中的 groupOwnerAddr 是真实 GO IP（getP2pLinkedInfo 全零的替代来源）
      try {
        let obj = JSON.parse(raw) as Record<string, Object>;
        let addrVal = obj['groupOwnerAddr'];
        if (addrVal !== undefined) {
          let addrText = addrVal as string;
          this.eventGroupOwnerAddr = addrText;
          // 探测目标默认指向 GO：仅在用户未自定义（空或默认值）时自动填充
          if ((this.probeIpInput.length === 0 || this.probeIpInput === '192.168.49.1') &&
            addrText.length > 0 && addrText !== '0.0.0.0') {
            this.probeIpInput = addrText;
          }
        }
      } catch (e) {
        // 解析失败忽略，保持上一次值
      }
    };
  }

  // ── 日志 ──

  /** 追加一条带时间戳的日志，超限丢弃最旧，同时输出 hilog */
  appendLog(action: string, resultText: string, level: string): void {
    let entry = new VerifyLogEntry();
    entry.timeText = formatTimeText(new Date());
    entry.action = action;
    entry.resultText = resultText;
    entry.level = level;
    this.logs.push(entry);
    if (this.logs.length > MAX_LOG_ENTRIES) {
      this.logs.shift();
    }
    if (level === 'error') {
      logger.error(`${action}: ${resultText}`);
    } else {
      logger.info(`${action}: ${resultText}`);
    }
  }

  /** 为指定日志条目添加人工备注 */
  onAddRemark(logIndex: number, remarkText: string): void {
    if (logIndex < 0 || logIndex >= this.logs.length) {
      return;
    }
    this.logs[logIndex].remark = remarkText;
    this.appendLog('备注', `日志#${logIndex} 备注: ${remarkText}`, 'info');
  }

  /** 清空日志流 */
  clearLogs(): void {
    this.logs = [];
  }

  /** 拼接全部日志文本（时间/操作/结果/备注），供剪贴板复制 */
  buildLogText(): string {
    let lines: Array<string> = [];
    for (let i = 0; i < this.logs.length; i++) {
      let e = this.logs[i];
      let remark = e.remark.length > 0 ? ` [备注: ${e.remark}]` : '';
      lines.push(`${e.timeText} [${e.level}] ${e.action}: ${e.resultText}${remark}`);
    }
    return lines.join('\n');
  }

  // ── 建组 ──

  /** 重新生成随机群组名与密码并填入表单 */
  refreshNames(): void {
    this.groupNameInput = generateRandomGroupName();
    this.passphraseInput = generateRandomPassphrase();
  }

  /** 创建 P2P 群组 */
  async onCreateGroup(): Promise<void> {
    if (this.groupNameInput.length === 0 || this.passphraseInput.length === 0) {
      this.appendLog('创建群组', '群组名与密码不能为空', 'error');
      return;
    }
    this.isGroupOperationBusy = true;
    this.appendLog('创建群组',
      `groupName=${this.groupNameInput} passphrase=${this.passphraseInput} goBand=${this.selectedGoBand}`, 'info');
    try {
      await this.service.createGroup(this.groupNameInput, this.passphraseInput, this.selectedGoBand);
      this.appendLog('创建群组', 'createGroup 调用成功，正在查询群组信息...', 'info');
      await this.onQueryGroup();
    } catch (e) {
      this.appendLog('创建群组', '失败: ' + String(e), 'error');
    } finally {
      this.isGroupOperationBusy = false;
    }
  }

  /** 删除 P2P 群组 */
  async onRemoveGroup(): Promise<void> {
    this.isGroupOperationBusy = true;
    try {
      await this.service.removeGroup();
      this.appendLog('删除群组', 'removeGroup 成功', 'info');
      this.groupInfo = null;
    } catch (e) {
      this.appendLog('删除群组', '失败: ' + String(e), 'error');
    } finally {
      this.isGroupOperationBusy = false;
    }
  }

  /** 查询当前群组信息 */
  async onQueryGroup(): Promise<void> {
    try {
      let info = await this.service.queryCurrentGroup();
      if (info === null) {
        this.groupInfo = null;
        this.appendLog('查询群组', '当前无群组', 'info');
      } else {
        this.groupInfo = info;
        this.appendLog('查询群组',
          `isP2pGo=${info.isGo} groupName=${info.groupName} passphrase=${info.passphrase} ` +
          `goIpAddress=${info.goIpAddress} interface=${info.interfaceName} frequency=${info.frequency} ` +
          `clientCount=${info.clientCount} ownerAddr=${info.ownerAddress} ` +
          `clients=[${info.clientDeviceAddresses.join(',')}]`, 'info');
      }
    } catch (e) {
      this.appendLog('查询群组', '失败: ' + String(e), 'error');
    }
  }

  // ── 凭据直连 ──

  /** 凭据直连（双路：静默 / 带用户确认弹窗） */
  async onConnectByCredential(): Promise<void> {
    if (this.credentialSsidInput.length === 0 || this.credentialPskInput.length === 0) {
      this.appendLog('凭据直连', 'SSID 与密码不能为空', 'error');
      return;
    }
    let modeText = this.withUserAction ? '带用户确认弹窗' : '静默';
    this.appendLog('凭据直连',
      `ssid=${this.credentialSsidInput} psk=${this.credentialPskInput} 模式=${modeText}`, 'info');
    try {
      let result = await this.service.addCandidateAndConnect(
        this.credentialSsidInput, this.credentialPskInput, this.withUserAction);
      this.credentialResult = result;
      this.appendLog('凭据直连', result, 'info');
    } catch (e) {
      this.credentialResult = String(e);
      this.appendLog('凭据直连', String(e), 'error');
    }
  }

  /** 断开并移除候选网络配置 */
  async onDisconnectCandidate(): Promise<void> {
    try {
      let result = await this.service.disconnectAndRemoveCandidate();
      this.appendLog('移除候选配置', result, 'info');
    } catch (e) {
      this.appendLog('移除候选配置', String(e), 'error');
    }
  }

  // ── 网络快照 ──

  /** 刷新网络状态快照 */
  async refreshNetwork(): Promise<void> {
    try {
      let snapshot = await this.service.getNetworkSnapshot();
      this.networkSnapshot = snapshot;
      this.appendLog('网络快照',
        `ip=${snapshot.ipAddressText} gateway=${snapshot.gatewayText} netmask=${snapshot.netmaskText} ` +
        `p2pState=${snapshot.p2pConnectStateText} isGO=${snapshot.isGroupOwner} ` +
        `groupOwnerAddr=${snapshot.groupOwnerAddr}`, 'info');
    } catch (e) {
      this.appendLog('网络快照', '失败: ' + String(e), 'error');
    }
  }

  // ── HTTP 服务 ──

  /** 启动极简 HTTP 服务（绑定当前群组 GO IP） */
  async onStartHttpServer(port: number): Promise<void> {
    let bindIp = '0.0.0.0';
    // 若已建组，优先绑定 GO IP（验证 P2P 接口可绑定）
    if (this.groupInfo !== null && this.groupInfo.goIpAddress.length > 0) {
      bindIp = this.groupInfo.goIpAddress;
    }
    this.appendLog('HTTP 服务', `启动中 bindIp=${bindIp} port=${port}`, 'info');
    try {
      let state = await this.service.startHttpServer(bindIp, port);
      this.httpServerState = state;
      this.appendLog('HTTP 服务',
        `已启动 bindAddress=${state.bindAddress} port=${state.port}`, 'info');
    } catch (e) {
      this.appendLog('HTTP 服务', '失败: ' + String(e), 'error');
    }
  }

  /** 停止 HTTP 服务 */
  async onStopHttpServer(): Promise<void> {
    try {
      let result = await this.service.stopHttpServer();
      this.httpServerState = new HttpServerState();
      this.appendLog('HTTP 服务', result, 'info');
    } catch (e) {
      this.appendLog('HTTP 服务', '失败: ' + String(e), 'error');
    }
  }

  /** 向指定 URL 发起 HTTP GET */
  async onHttpGet(): Promise<void> {
    if (this.httpUrlInput.length === 0) {
      this.appendLog('HTTP 请求', 'URL 不能为空', 'error');
      return;
    }
    this.appendLog('HTTP 请求', `GET ${this.httpUrlInput}`, 'info');
    try {
      let result = await this.service.httpGet(this.httpUrlInput);
      this.httpRequestResult = result;
      this.appendLog('HTTP 请求', result, 'info');
    } catch (e) {
      this.httpRequestResult = String(e);
      this.appendLog('HTTP 请求', String(e), 'error');
    }
  }

  // ── p2pConnect 实验 ──

  /**
   * 应用场景预设：只填充非设备地址字段（地址为每次实验人工采集）。
   * mta-credential 预设复用实验分区已输入的 groupName/passphrase，
   * 为空时提示先填写（来源为 MVP 接收页「P2P 凭据」卡片抄录）。
   */
  onApplyPreset(kind: number): void {
    if (kind === PRESET_MTA_CREDENTIAL) {
      if (this.p2pGroupNameInput.length === 0 || this.p2pPassphraseInput.length === 0) {
        this.appendLog('实验预设', 'MTA 凭据注入需要先填写组名/SSID 与密码（来自 MVP 接收页抄录）', 'error');
        return;
      }
    }
    let config = buildPresetConfig(kind, this.p2pGroupNameInput, this.p2pPassphraseInput);
    this.p2pAddressTypeIndex = config.deviceAddressType;
    this.p2pNetIdInput = config.netId.toString();
    this.p2pPassphraseInput = config.passphrase;
    this.p2pGroupNameInput = config.groupName;
    this.p2pGoBandIndex = config.goBand;
    this.appendLog('实验预设',
      `${presetKindText(kind)}: netId=${config.netId} 地址类型=${config.deviceAddressType} ` +
      `groupName=${config.groupName} passphrase=${config.passphrase}（设备地址未改动）`, 'info');
  }

  /** 校验实验配置并发起 p2pConnect */
  async onP2pConnect(): Promise<void> {
    let config = new P2pConnectConfigView();
    config.deviceAddress = this.p2pDeviceAddressInput.trim();
    if (!isMacAddressText(config.deviceAddress)) {
      this.appendLog('实验连接', '设备地址格式非法，需形如 XX:XX:XX:XX:XX:XX', 'error');
      return;
    }
    config.deviceAddressType = this.p2pAddressTypeIndex;
    let netId = parseInt(this.p2pNetIdInput);
    if (isNaN(netId)) {
      this.appendLog('实验连接', 'netId 必须是整数（-1 临时组 / -2 永久组）', 'error');
      return;
    }
    config.netId = netId;
    config.passphrase = this.p2pPassphraseInput;
    config.groupName = this.p2pGroupNameInput;
    config.goBand = this.p2pGoBandIndex;
    this.appendLog('实验连接',
      `deviceAddress=${config.deviceAddress} type=${config.deviceAddressType} netId=${config.netId} ` +
      `groupName=${config.groupName} passphrase=${config.passphrase} goBand=${config.goBand}`, 'info');
    try {
      let result = await this.service.p2pConnect(config);
      this.p2pConnectResult = result;
      this.appendLog('实验连接', result, 'info');
    } catch (e) {
      this.p2pConnectResult = String(e);
      this.appendLog('实验连接', String(e), 'error');
    }
  }

  /** 中止进行中的 p2pConnect */
  async onP2pCancelConnect(): Promise<void> {
    try {
      let result = await this.service.p2pCancelConnect();
      this.appendLog('实验连接', result, 'info');
    } catch (e) {
      this.appendLog('实验连接', String(e), 'error');
    }
  }

  // ── 网络列表快照 ──

  /** 刷新系统网络列表（getAllNets + 连接属性） */
  async onRefreshNetworkList(): Promise<void> {
    try {
      let list = await this.service.listNetworks();
      this.networkList = list;
      if (list.length === 0) {
        this.appendLog('网络列表', '当前无网络条目', 'info');
        return;
      }
      let p2pCount = 0;
      let parts: Array<string> = [];
      for (let i = 0; i < list.length; i++) {
        let e = list[i];
        if (e.isLikelyP2p) {
          p2pCount = p2pCount + 1;
        }
        let mark = e.isLikelyP2p ? ' [疑似P2P]' : '';
        parts.push(`net=${e.netId} if=${e.interfaceName} addr=[${e.addresses.join(',')}]${mark}`);
      }
      this.appendLog('网络列表', `共 ${list.length} 条，疑似 P2P ${p2pCount} 条: ${parts.join(' | ')}`, 'info');
    } catch (e) {
      this.appendLog('网络列表', '失败: ' + String(e), 'error');
    }
  }

  // ── TCP 探测 ──

  /** TCP 可达性探测（单实例，探测中防重入） */
  async onProbeTcp(): Promise<void> {
    if (this.isProbeBusy) {
      this.appendLog('TCP 探测', '探测进行中，请稍候', 'error');
      return;
    }
    let ip = this.probeIpInput.trim();
    if (ip.length === 0) {
      this.appendLog('TCP 探测', '目标 IP 不能为空', 'error');
      return;
    }
    let port = parseInt(this.probePortInput);
    if (isNaN(port) || port <= 0 || port > 65535) {
      this.appendLog('TCP 探测', '端口无效: ' + this.probePortInput, 'error');
      return;
    }
    this.isProbeBusy = true;
    this.appendLog('TCP 探测', `连接 ${ip}:${port} ...`, 'info');
    try {
      let result = await this.service.probeTcp(ip, port);
      this.probeResult = result;
      this.appendLog('TCP 探测', result.detail, result.ok ? 'info' : 'error');
    } catch (e) {
      this.appendLog('TCP 探测', '探测异常: ' + String(e), 'error');
    } finally {
      this.isProbeBusy = false;
    }
  }

  // ── P2P 设备发现 ──

  /** 开始 P2P 设备发现（先申请定位权限，拒绝时提示但不阻止） */
  async onStartDiscovery(): Promise<void> {
    if (this.isDiscovering) {
      this.appendLog('设备发现', '已在发现中，请先停止', 'error');
      return;
    }
    let context = this.appContext;
    if (context === undefined) {
      this.appendLog('设备发现', '缺少应用上下文（页面未注入）', 'error');
      return;
    }
    try {
      let granted = await this.service.ensureLocationPermission(context);
      if (!granted) {
        this.appendLog('设备发现', '定位权限未授予，发现结果可能为空', 'error');
      }
      let result = await this.service.startDiscovery();
      this.isDiscovering = true;
      this.appendLog('设备发现', result, 'info');
    } catch (e) {
      this.appendLog('设备发现', String(e), 'error');
    }
  }

  /** 停止 P2P 设备发现 */
  async onStopDiscovery(): Promise<void> {
    try {
      let result = await this.service.stopDiscovery();
      this.isDiscovering = false;
      this.appendLog('设备发现', result, 'info');
    } catch (e) {
      this.appendLog('设备发现', String(e), 'error');
    }
  }

  /** 点击发现设备条目：填充实验分区地址字段（不自动发起连接） */
  onPickDiscoveredDevice(device: P2pDiscoveredDeviceView): void {
    this.p2pDeviceAddressInput = device.deviceAddress;
    this.p2pAddressTypeIndex = device.deviceAddressType;
    let nameText = device.deviceName.length > 0 ? device.deviceName : device.deviceAddress;
    this.appendLog('设备发现', `已从发现列表填充地址与地址类型: ${nameText} → ${device.deviceAddress}`, 'info');
  }

  /**
   * 直接连接发现设备：用该设备地址 + 系统返回的地址类型，
   * 叠加实验分区当前的 netId/组名/密码/频段发起标准 P2P 协商（默认 netId=-2、凭据空）。
   * 需切换场景（如标准协商 netId=-1）时，可先点预设再连接。
   */
  async onConnectDiscoveredDevice(device: P2pDiscoveredDeviceView): Promise<void> {
    let config = new P2pConnectConfigView();
    config.deviceAddress = device.deviceAddress;
    config.deviceAddressType = device.deviceAddressType;
    let netId = parseInt(this.p2pNetIdInput);
    config.netId = isNaN(netId) ? -2 : netId;
    config.passphrase = this.p2pPassphraseInput;
    config.groupName = this.p2pGroupNameInput;
    config.goBand = this.p2pGoBandIndex;
    let nameText = device.deviceName.length > 0 ? device.deviceName : device.deviceAddress;
    this.appendLog('设备发现',
      `直接连接 ${nameText}（地址类型=${config.deviceAddressType} netId=${config.netId} ` +
      `组名=${config.groupName} 密码=${config.passphrase} goBand=${config.goBand}）`, 'info');
    try {
      let result = await this.service.p2pConnect(config);
      this.p2pConnectResult = result;
      this.appendLog('实验连接', result, 'info');
    } catch (e) {
      this.p2pConnectResult = String(e);
      this.appendLog('实验连接', String(e), 'error');
    }
  }

  // ── 清理 ──

  /** 一键清理：删组 → 停服务 → 移除候选配置 */
  async cleanupAll(): Promise<void> {
    if (this.groupInfo !== null) {
      try {
        await this.service.removeGroup();
        this.groupInfo = null;
        this.appendLog('清理', '已删除 P2P 群组', 'info');
      } catch (e) {
        this.appendLog('清理', '删除群组失败: ' + String(e), 'error');
      }
    }
    if (this.httpServerState.running) {
      try {
        let result = await this.service.stopHttpServer();
        this.httpServerState = new HttpServerState();
        this.appendLog('清理', result, 'info');
      } catch (e) {
        this.appendLog('清理', '停止 HTTP 服务失败: ' + String(e), 'error');
      }
    }
    try {
      let result = await this.service.disconnectAndRemoveCandidate();
      this.appendLog('清理', result, 'info');
    } catch (e) {
      this.appendLog('清理', '移除候选配置失败: ' + String(e), 'error');
    }
  }
}
