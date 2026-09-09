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
  generateRandomGroupName,
  generateRandomPassphrase,
  formatTimeText
} from '../model/mta/P2pVerifyModels';
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

  // ── 日志流 ──
  @Trace public logs: Array<VerifyLogEntry> = []

  private service: P2pVerifyService = new P2pVerifyService();
  private handlers: P2pEventHandlers = new P2pEventHandlers();

  // ── 生命周期 ──

  /** 页面 aboutToAppear：注册事件并记录初始状态 */
  loadInitial(): void {
    this.bindHandlers();
    this.service.registerP2pEvents(this.handlers);
    this.refreshNames();
    this.appendLog('初始化', '验证页面就绪，事件已注册', 'info');
    this.refreshNetwork();
  }

  /** 页面 aboutToDisappear：反注册事件并执行资源清理 */
  destroy(): void {
    this.service.unregisterP2pEvents();
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
          this.eventGroupOwnerAddr = addrVal as string;
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
          `clientCount=${info.clientCount} ownerAddr=${info.ownerAddress}`, 'info');
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
