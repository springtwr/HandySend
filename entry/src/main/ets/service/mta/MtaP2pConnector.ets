/**
 * MtaP2pConnector.ets — MTA 接收端 P2P 连接
 *
 * 凭据直连：把发送方 WiFi Direct 组当普通 WPA2 网络直连
 * （addCandidateConfig + connectToCandidateConfig），以 getLinkedInfoSync().ssid 匹配目标 SSID 确认，
 * GO IP 取 getIpInfo().gateway，缺失时以 192.168.49.1 兜底。
 */

import { wifiManager } from '@kit.ConnectivityKit';
import { connection } from '@kit.NetworkKit';
import { MtaP2pEventHandlers } from '../../model/mta/MtaProtocolModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaP2pConnector', '互传P2P');

/** 将 IpInfo 的十进制整数 IPv4 转为点分十进制文本（0 → "0.0.0.0"） */
function ipNumberToText(n: number): string {
  let v = n >>> 0;
  let b0 = (v >> 24) & 0xff;
  let b1 = (v >> 16) & 0xff;
  let b2 = (v >> 8) & 0xff;
  let b3 = v & 0xff;
  return `${b0}.${b1}.${b2}.${b3}`;
}

/** P2P 连接结果 */
export class P2pConnectResult {
  /** 是否已确认连接成功 */
  connected: boolean = false;
  /** 可用 GO 网关地址（含兜底值） */
  goIp: string = '';
  /** 结果描述 */
  detail: string = '';
}

/** MTA 接收端 P2P 连接器 */
export class MtaP2pConnector {
  /** 凭据直连添加的候选网络 ID，供后续移除 */
  private candidateNetworkId: number = -1;
  /** 最近一次事件回调的 GO IP */
  private goIp: string = '';
  /** 是否已连接 */
  private connected: boolean = false;
  /** 本次直连的目标 SSID（用于判定是否已连上目标 WiFi Direct 组） */
  private targetSsid: string = '';
  /** 事件回调集合 */
  private handlers: MtaP2pEventHandlers | null = null;
  /** 等待连接事件的 resolver */
  private waitResolver: ((ok: boolean) => void) | null = null;
  /** 连接等待超时定时器 */
  private timerId: number = -1;
  /** 连接确认轮询定时器 */
  private pollTimerId: number = -1;
  /** 已绑定的 P2P 网络句柄（用于解除绑定） */
  private boundNet: connection.NetHandle | null = null;

  // ── 事件注册 / 反注册 ──

  /** 注册 P2P / WLAN 事件（凭据直连靠 wifiConnectionChange 确认，p2pConnectionChange 仅作辅助） */
  registerEvents(handlers: MtaP2pEventHandlers): void {
    if (this.handlers !== null) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      wifiManager.on('p2pConnectionChange', (info: wifiManager.WifiP2pLinkedInfo) => {
        this.handleP2pConnection(info);
      });
    } catch (e) {
      logger.warn('p2pConnectionChange 注册失败: ' + errorText(e));
    }
    try {
      wifiManager.on('wifiConnectionChange', (state: number) => {
        if (this.handlers !== null) {
          this.handlers.onWifiConnectionChange(`state=${state}`);
        }
        this.tryResolve();
      });
    } catch (e) {
      logger.warn('wifiConnectionChange 注册失败: ' + errorText(e));
    }
    try {
      wifiManager.on('p2pStateChange', (state: number) => {
        if (this.handlers !== null) {
          this.handlers.onP2pStateChange(`state=${state}`);
        }
      });
    } catch (e) {
      logger.warn('p2pStateChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册 P2P / WLAN 事件 */
  unregisterEvents(): void {
    try {
      wifiManager.off('p2pConnectionChange');
    } catch (e) {
      logger.warn('p2pConnectionChange 反注册失败: ' + errorText(e));
    }
    try {
      wifiManager.off('wifiConnectionChange');
    } catch (e) {
      logger.warn('wifiConnectionChange 反注册失败: ' + errorText(e));
    }
    try {
      wifiManager.off('p2pStateChange');
    } catch (e) {
      logger.warn('p2pStateChange 反注册失败: ' + errorText(e));
    }
    this.handlers = null;
  }

  /** 处理 p2pConnectionChange：仅作辅助信号，更新 GO IP 并尝试唤醒等待者 */
  private handleP2pConnection(info: wifiManager.WifiP2pLinkedInfo): void {
    let stateText = info.connectState === 1 ? 'CONNECTED' : 'DISCONNECTED';
    let addr = info.groupOwnerAddr;
    if (info.connectState === 1) {
      if (addr !== undefined && addr.length > 0 && addr !== '0.0.0.0') {
        this.goIp = addr;
      }
    }
    let summary = `connectState=${stateText} isGroupOwner=${info.isGroupOwner} groupOwnerAddr=${addr}`;
    if (this.handlers !== null) {
      this.handlers.onP2pConnectionChange(summary);
    }
    if (info.connectState === 1) {
      // P2P 层已连上：视为成功（SSID 轮询仍作兜底）
      if (this.waitResolver !== null) {
        this.finishWait(true);
      }
    } else {
      this.tryResolve();
    }
  }

  /**
   * 检测是否已连上目标 WiFi Direct 组：以 getLinkedInfoSync().ssid 与目标 SSID 比对为准，
   * 连上后从 getIpInfo().gateway 取 GO IP。未连接/查询失败返回 false。
   */
  private checkLinked(): boolean {
    let linkedSsid = '';
    try {
      linkedSsid = wifiManager.getLinkedInfoSync().ssid;
    } catch (e) {
      return false;
    }
    if (this.targetSsid.length === 0 || linkedSsid !== this.targetSsid) {
      return false;
    }
    let goIp = '';
    try {
      let gatewayText = ipNumberToText(wifiManager.getIpInfo().gateway);
      if (gatewayText !== '0.0.0.0') {
        goIp = gatewayText;
      }
    } catch (e) {
      logger.warn('getIpInfo 失败: ' + errorText(e));
    }
    this.connected = true;
    if (goIp.length > 0) {
      this.goIp = goIp;
    }
    return true;
  }

  /** 轮询/事件触发：若已连上目标组则结束等待 */
  private tryResolve(): void {
    if (this.waitResolver === null) {
      return;
    }
    if (this.checkLinked()) {
      this.finishWait(true);
    }
  }

  /** 结束等待：清理定时器、回调 GO IP 并 resolve */
  private finishWait(ok: boolean): void {
    let resolver = this.waitResolver;
    this.waitResolver = null;
    this.clearWaitTimer();
    if (ok && this.handlers !== null) {
      this.handlers.onGoIp(this.resolveGoIp());
    }
    if (resolver !== null) {
      resolver(ok);
    }
  }

  /** 清除连接等待与轮询定时器 */
  private clearWaitTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (this.pollTimerId >= 0) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
  }

  /** 等待连上目标 SSID：先立即检测，随后轮询兜底，超时返回 false */
  private waitConnected(timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (this.checkLinked()) {
        resolve(true);
        return;
      }
      this.waitResolver = resolve;
      this.clearWaitTimer();
      this.pollTimerId = setInterval(() => {
        this.tryResolve();
      }, MtaConstants.P2P_POLL_INTERVAL_MS);
      this.timerId = setTimeout(() => {
        this.finishWait(false);
      }, timeoutMs);
    });
  }

  /** 解析可用 GO IP：网关/事件回调值优先，缺失时用默认网关兜底 */
  private resolveGoIp(): string {
    return this.goIp.length > 0 ? this.goIp : MtaConstants.DEFAULT_GO_IP;
  }

  /**
   * 凭据直连：添加候选配置 → 静默连接 → 等待 p2pConnectionChange。
   * 超时或事件未确认时仍返回兜底 GO IP，由调用方决定是否继续。
   */
  async connectAndWait(ssid: string, psk: string, timeoutMs: number): Promise<P2pConnectResult> {
    let result = new P2pConnectResult();
    if (ssid.length === 0) {
      result.detail = 'SSID 为空，无法凭据直连';
      return result;
    }
    let config: wifiManager.WifiDeviceConfig = {
      ssid: ssid,
      preSharedKey: psk,
      securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK
    };
    let networkId = -1;
    try {
      networkId = await wifiManager.addCandidateConfig(config);
    } catch (e) {
      result.detail = '添加候选配置失败: ' + errorText(e);
      return result;
    }
    this.candidateNetworkId = networkId;
    this.connected = false;
    this.goIp = '';
    this.targetSsid = ssid;
    let wait = this.waitConnected(timeoutMs);
    try {
      wifiManager.connectToCandidateConfig(networkId);
    } catch (e) {
      this.finishWait(false);
      result.detail = `已添加候选配置 networkId=${networkId}，连接发起异常: ` + errorText(e);
      return result;
    }
    let ok = await wait;
    result.connected = ok;
    result.goIp = this.resolveGoIp();
    if (ok) {
      result.detail = `凭据直连成功，已连上 ${ssid}，GO IP=${result.goIp}`;
    } else {
      result.detail = `未在 ${timeoutMs}ms 内检测到已连上 ${ssid}，使用兜底 GO IP=${result.goIp}`;
    }
    return result;
  }

  /** 当前是否已连接 WiFi */
  isWifiConnected(): boolean {
    try {
      return wifiManager.isConnected();
    } catch (e) {
      logger.warn('isConnected 查询失败: ' + errorText(e));
      return false;
    }
  }

  /** 当前网络状态摘要（本机 IP / 网关 / WiFi 是否连接），用于诊断 WS 不可达 */
  getNetworkInfoText(): string {
    let parts: Array<string> = [];
    try {
      let ip = wifiManager.getIpInfo();
      parts.push(`ip=${ipNumberToText(ip.ipAddress)} gw=${ipNumberToText(ip.gateway)}`);
    } catch (e) {
      parts.push('getIpInfo 失败: ' + errorText(e));
    }
    parts.push(`wifiConnected=${this.isWifiConnected()}`);
    return parts.join(' ');
  }

  /** 当前已连 WiFi 的 SSID（查询失败/未连返回空串），用于确认是否已关联到目标组 */
  getLinkedSsidText(): string {
    try {
      return wifiManager.getLinkedInfoSync().ssid;
    } catch (e) {
      return '';
    }
  }

  /**
   * 汇总网络并存快照：本机 IP/网关、默认网络、getAllNets 条目（接口名/链路地址/是否疑似 P2P）。
   * 单个条目查询失败不影响其余，全部异步异常文本化，不抛出。
   */
  async getNetworkSummary(): Promise<string> {
    let parts: Array<string> = [];
    try {
      let ip = wifiManager.getIpInfo();
      parts.push(`本机 ip=${ipNumberToText(ip.ipAddress)} gw=${ipNumberToText(ip.gateway)}`);
    } catch (e) {
      parts.push('getIpInfo 失败: ' + errorText(e));
    }
    try {
      let defaultNet = await connection.getDefaultNet();
      parts.push(`默认网络 netId=${defaultNet.netId}`);
    } catch (e) {
      parts.push('getDefaultNet 失败: ' + errorText(e));
    }
    try {
      let nets = await connection.getAllNets();
      let netTexts: Array<string> = [];
      for (let i = 0; i < nets.length; i++) {
        let net = nets[i];
        try {
          let props = await connection.getConnectionProperties(net);
          let addrs: Array<string> = [];
          let la = props.linkAddresses;
          if (la !== undefined) {
            for (let j = 0; j < la.length; j++) {
              let a = la[j].address;
              if (a !== undefined) {
                addrs.push(a.address);
              }
            }
          }
          let iface = props.interfaceName !== undefined ? props.interfaceName : '';
          netTexts.push(`net=${net.netId} if=${iface} addr=[${addrs.join(',')}] ` +
            `疑似P2P=${this.isLikelyP2p(iface, addrs)}`);
        } catch (e) {
          netTexts.push(`net=${net.netId} 属性查询失败`);
        }
      }
      parts.push(`网络列表(${nets.length} 条): ${netTexts.join(' | ')}`);
    } catch (e) {
      parts.push('getAllNets 失败: ' + errorText(e));
    }
    return parts.join('；');
  }

  /** 判断某网络是否疑似 P2P（接口名含 p2p，或链路地址落在默认 P2P 网段） */
  private isLikelyP2p(iface: string, addrs: Array<string>): boolean {
    if (iface.length > 0 && iface.toLowerCase().includes('p2p')) {
      return true;
    }
    let dot = MtaConstants.DEFAULT_GO_IP.lastIndexOf('.');
    let prefix = dot > 0 ? MtaConstants.DEFAULT_GO_IP.substring(0, dot + 1) : '';
    if (prefix.length === 0) {
      return false;
    }
    for (let i = 0; i < addrs.length; i++) {
      if (addrs[i].startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 将 App 的网络请求绑定到 P2P 网络（本机 P2P IP 所在网络）。
   * 原 WiFi 仍在时 OS 可能把 App 流量绑在原 WiFi 上，导致到 GO 的 WS/下载不可达。
   */
  async bindP2pNetwork(goIp: string): Promise<string> {
    for (let i = 0; i < MtaConstants.P2P_BIND_MAX_POLLS; i++) {
      let net = await this.findP2pNet(goIp);
      if (net !== null) {
        try {
          await connection.setAppNet(net);
          this.boundNet = net;
          return `已绑定 App 网络到 netId=${net.netId}`;
        } catch (e) {
          return 'setAppNet 失败: ' + errorText(e);
        }
      }
      await this.sleepMs(MtaConstants.P2P_BIND_POLL_INTERVAL_MS);
    }
    let nets = await this.describeNets();
    return `未找到 P2P 网络（GO=${goIp}），网络列表: ${nets}`;
  }

  /** 查找 P2P 网络句柄（接口名含 p2p，或链路地址与 GO 同网段） */
  private async findP2pNet(goIp: string): Promise<connection.NetHandle | null> {
    try {
      let nets = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        let net = nets[i];
        try {
          let props = await connection.getConnectionProperties(net);
          if (this.netMatches(props, goIp)) {
            return net;
          }
        } catch (e) {
          logger.warn('getConnectionProperties 失败: ' + errorText(e));
        }
      }
    } catch (e) {
      logger.warn('getAllNets 失败: ' + errorText(e));
    }
    return null;
  }

  /** 列出所有网络摘要（诊断用） */
  private async describeNets(): Promise<string> {
    let parts: Array<string> = [];
    try {
      let nets = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        let net = nets[i];
        try {
          let props = await connection.getConnectionProperties(net);
          let addrs: Array<string> = [];
          let la = props.linkAddresses;
          if (la !== undefined) {
            for (let j = 0; j < la.length; j++) {
              let a = la[j].address;
              if (a !== undefined) {
                addrs.push(a.address);
              }
            }
          }
          parts.push(`net=${net.netId} if=${props.interfaceName} addr=[${addrs.join(',')}]`);
        } catch (e) {
          parts.push(`net=${net.netId} 属性查询失败`);
        }
      }
    } catch (e) {
      return 'getAllNets 失败: ' + errorText(e);
    }
    return parts.join(' | ');
  }

  /** 解除 App 网络绑定（恢复系统默认网络选择） */
  async unbindP2pNetwork(): Promise<void> {
    let net = this.boundNet;
    if (net === null) {
      return;
    }
    this.boundNet = null;
    try {
      net.netId = 0;
      await connection.setAppNet(net);
    } catch (e) {
      logger.warn('解除网络绑定失败: ' + errorText(e));
    }
  }

  /** 判断某网络是否为 P2P 网络（接口名含 p2p，或链路地址与 GO IP 同网段） */
  private netMatches(props: connection.ConnectionProperties, goIp: string): boolean {
    let iface = props.interfaceName;
    if (iface !== undefined && iface.length > 0 && iface.toLowerCase().includes('p2p')) {
      return true;
    }
    let dot = goIp.lastIndexOf('.');
    let prefix = dot > 0 ? goIp.substring(0, dot + 1) : '';
    if (prefix.length === 0) {
      return false;
    }
    let addrs = props.linkAddresses;
    if (addrs === undefined) {
      return false;
    }
    for (let j = 0; j < addrs.length; j++) {
      let addr = addrs[j].address;
      if (addr !== undefined && addr.address.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /** 延时辅助 */
  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 断开连接：移除凭据直连添加的候选配置并解除网络绑定 */
  async disconnect(): Promise<string> {
    this.finishWait(false);
    this.targetSsid = '';
    await this.unbindP2pNetwork();
    let steps: Array<string> = [];
    if (this.candidateNetworkId >= 0) {
      try {
        let id = this.candidateNetworkId;
        wifiManager.removeCandidateConfig(id);
        steps.push(`已移除候选配置 networkId=${id}`);
      } catch (e) {
        steps.push('移除候选配置失败: ' + errorText(e));
      }
      this.candidateNetworkId = -1;
    }
    this.connected = false;
    this.goIp = '';
    return steps.length > 0 ? steps.join('；') : '无待清理的连接';
  }

  /** 释放资源（反注册事件、清理连接） */
  destroy(): void {
    this.clearWaitTimer();
    this.disconnect().catch((): void => {
    });
    this.unregisterEvents();
  }
}
