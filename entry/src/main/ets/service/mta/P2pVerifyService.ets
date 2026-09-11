/**
 * P2pVerifyService.ets — MTA P2P 验证服务
 *
 * 封装 @ohos.wifiManager 的 P2P 相关接口、P2P/WLAN 事件注册反注册，
 * 以及极简 HTTP 服务（TCPSocketServer）与 HTTP 请求（@ohos.net.http）。
 * 本服务只采集/转发数据，不持有页面状态；错误统一文本化（[错误码] 信息）上抛。
 */

import { wifiManager } from '@kit.ConnectivityKit';
import { http, socket, connection } from '@kit.NetworkKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import {
  P2pGroupInfoView,
  P2pConnectConfigView,
  NetworkListEntry,
  TcpProbeResult,
  P2pDiscoveredDeviceView,
  NetworkSnapshot,
  HttpServerState,
  numberIpToText,
  formatTimeText
} from '../../model/mta/P2pVerifyModels';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaP2pVerify');

/** 事件回调集合：由 ViewModel 注入处理函数 */
export class P2pEventHandlers {
  /** p2pConnectionChange 事件回调（连接状态变化摘要） */
  onP2pConnectionChange: (info: string) => void = (info: string): void => {
  };
  /** p2pStateChange 事件回调（P2P 总开关变化） */
  onP2pStateChange: (state: string) => void = (state: string): void => {
  };
  /** wifiConnectionChange 事件回调（WLAN 连接状态变化） */
  onWifiConnectionChange: (state: string) => void = (state: string): void => {
  };
  /** p2pConnectionChange 事件原始 JSON 文本 */
  onRawP2pConnection: (raw: string) => void = (raw: string): void => {
  };
}

/**
 * 将 wifiManager 同步调用的异常统一转换为可读文本。
 * 系统异常多为 BusinessError（含 code/message 字段），
 * 通过 Record 读取字段，避免 instanceof 类型值判断。
 */
function errorText(e: Object): string {
  let obj = e as Record<string, Object>;
  let codeVal = obj['code'];
  let msgVal = obj['message'];
  if (codeVal !== undefined && msgVal !== undefined) {
    return `[${codeVal}] ${msgVal}`;
  }
  if (e instanceof Error) {
    let err = e as Error;
    return err.message.length > 0 ? err.message : '未知错误';
  }
  return '未知错误';
}

/** P2P 连接状态枚举 → 文本 */
function connectStateText(state: number): string {
  switch (state) {
    case 0:
      return 'DISCONNECTED';
    case 1:
      return 'CONNECTED';
    default:
      return 'UNKNOWN';
  }
}

/** TCP 探测失败原因文本：对 2301115（EINPROGRESS，连接未完成）给出可读解释 */
function probeErrorText(e: Object): string {
  let base = errorText(e);
  if (base.includes('2301115')) {
    return base + '（连接未完成：目标不可达，可能无到该网段的路由或 P2P 网络未注册）';
  }
  return base;
}

/**
 * P2P 验证服务。
 * 所有 Promise 方法失败时 reject 文本描述（调用方直接记入日志）。
 */
export class P2pVerifyService {
  /** 凭据直连成功后记录的候选网络 ID，供后续移除 */
  private candidateNetworkId: number = -1;
  /** 极简 HTTP 服务实例 */
  private tcpServer: socket.TCPSocketServer | null = null;
  /** 当前已注册的事件处理 */
  private handlers: P2pEventHandlers | null = null;
  /** p2pPeerDeviceChange 事件回调（发现列表驱动，null 表示未注册） */
  private discoveryHandler: ((devices: Array<P2pDiscoveredDeviceView>) => void) | null = null;

  // ── 事件注册 / 反注册（US 基础设施） ──

  /** 注册四类 P2P/WLAN 事件；仅当已注册过（handlers 非空）时先反注册旧回调 */
  registerP2pEvents(handlers: P2pEventHandlers): void {
    if (this.handlers !== null) {
      this.unregisterP2pEvents();
    }
    this.handlers = handlers;
    try {
      wifiManager.on('p2pConnectionChange', (info: wifiManager.WifiP2pLinkedInfo) => {
        let raw = JSON.stringify(info);
        let summary = `connectState=${connectStateText(info.connectState)} isGroupOwner=${info.isGroupOwner} groupOwnerAddr=${info.groupOwnerAddr}`;
        if (this.handlers !== null) {
          this.handlers.onP2pConnectionChange(summary);
          this.handlers.onRawP2pConnection(raw);
        }
      });
    } catch (e) {
      logger.warn('P2P: p2pConnectionChange 注册失败: ' + errorText(e));
    }
    try {
      wifiManager.on('p2pStateChange', (state: number) => {
        if (this.handlers !== null) {
          this.handlers.onP2pStateChange(`state=${state}`);
        }
      });
    } catch (e) {
      logger.warn('P2P: p2pStateChange 注册失败: ' + errorText(e));
    }
    try {
      wifiManager.on('wifiConnectionChange', (state: number) => {
        if (this.handlers !== null) {
          this.handlers.onWifiConnectionChange(`state=${state}`);
        }
      });
    } catch (e) {
      logger.warn('P2P: wifiConnectionChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册全部 P2P/WLAN 事件 */
  unregisterP2pEvents(): void {
    try {
      wifiManager.off('p2pConnectionChange');
    } catch (e) {
      logger.warn('P2P: p2pConnectionChange 反注册失败: ' + errorText(e));
    }
    try {
      wifiManager.off('p2pStateChange');
    } catch (e) {
      logger.warn('P2P: p2pStateChange 反注册失败: ' + errorText(e));
    }
    try {
      wifiManager.off('wifiConnectionChange');
    } catch (e) {
      logger.warn('P2P: wifiConnectionChange 反注册失败: ' + errorText(e));
    }
    this.handlers = null;
  }

  // ── 建组 / 删组 / 查组 ──

  /** 创建 P2P 群组（临时组 netId=-1），失败 reject 错误文本 */
  createGroup(groupName: string, passphrase: string, goBand: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        let config: wifiManager.WifiP2PConfig = {
          deviceAddress: '',
          netId: -1,
          passphrase: passphrase,
          groupName: groupName,
          goBand: goBand
        };
        wifiManager.createGroup(config);
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 删除当前 P2P 群组 */
  removeGroup(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        wifiManager.removeGroup();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 查询当前群组信息，未建组时返回 null */
  queryCurrentGroup(): Promise<P2pGroupInfoView | null> {
    return new Promise<P2pGroupInfoView | null>((resolve, reject) => {
      wifiManager.getCurrentGroup()
        .then((group: wifiManager.WifiP2pGroupInfo) => {
          let view = new P2pGroupInfoView();
          view.isGo = group.isP2pGo;
          view.groupName = group.groupName;
          view.passphrase = group.passphrase;
          view.goIpAddress = group.goIpAddress;
          view.interfaceName = group.interface;
          view.frequency = group.frequency;
          // 无客户端接入时 clientDevices 可能为 undefined，需容错
          let clients = group.clientDevices;
          view.clientCount = clients === undefined ? 0 : clients.length;
          // 采集已接入客户端设备地址（A 组实验对端标识来源；系统可能返回隐私化随机 MAC）
          let clientAddrs: Array<string> = [];
          if (clients !== undefined) {
            for (let i = 0; i < clients.length; i++) {
              let dev = clients[i];
              if (dev !== undefined && dev.deviceAddress !== undefined && dev.deviceAddress.length > 0) {
                clientAddrs.push(dev.deviceAddress);
              }
            }
          }
          view.clientDeviceAddresses = clientAddrs;
          // 群主设备地址（文档说明普通应用返回随机地址，用于与 getP2pLocalDevice 交叉验证）
          let owner = group.ownerInfo;
          view.ownerAddress = owner === undefined ? '' : owner.deviceAddress;
          resolve(view);
        })
        .catch((e: BusinessError) => {
          // 2801000 表示当前无群组，作为"未建组"处理而非错误
          if (e.code === 2801000) {
            resolve(null);
          } else {
            reject(errorText(e));
          }
        });
    });
  }

  // ── 凭据直连 ──

  /**
   * 添加候选网络配置并发起连接（双路）。
   * withUserAction=true 走 connectToCandidateConfigWithUserAction（系统弹窗确认，可区分用户响应），
   * withUserAction=false 走 connectToCandidateConfig（静默连接）。
   * 返回逐步结果描述文本。
   */
  addCandidateAndConnect(ssid: string, psk: string, withUserAction: boolean): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let config: wifiManager.WifiDeviceConfig = {
        ssid: ssid,
        preSharedKey: psk,
        securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK
      };
      wifiManager.addCandidateConfig(config)
        .then((networkId: number) => {
          this.candidateNetworkId = networkId;
          let step = `添加候选配置成功 networkId=${networkId}，开始连接...`;
          if (withUserAction) {
            wifiManager.connectToCandidateConfigWithUserAction(networkId)
              .then(() => {
                resolve(step + ' 带用户确认连接发起成功（等待 wifiConnectionChange 事件确认结果）');
              })
              .catch((e: BusinessError) => {
                // 2501005 用户未响应 / 2501006 用户拒绝，均属可预期结果，记录为用户响应
                reject(step + ' 连接失败: ' + errorText(e));
              });
          } else {
            try {
              wifiManager.connectToCandidateConfig(networkId);
              resolve(step + ' 连接已发起（静默模式，结果见 wifiConnectionChange 事件与网络快照）');
            } catch (e) {
              reject(step + ' 连接发起异常: ' + errorText(e));
            }
          }
        })
        .catch((e: BusinessError) => {
          reject('添加候选配置失败: ' + errorText(e));
        });
    });
  }

  /** 断开并移除凭据直连添加的候选网络配置 */
  disconnectAndRemoveCandidate(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      if (this.candidateNetworkId < 0) {
        resolve('无待移除的候选配置（请先执行凭据直连）');
        return;
      }
      try {
        wifiManager.removeCandidateConfig(this.candidateNetworkId);
        let id = this.candidateNetworkId;
        this.candidateNetworkId = -1;
        resolve(`已移除候选配置 networkId=${id}`);
      } catch (e) {
        reject('移除候选配置失败: ' + errorText(e));
      }
    });
  }

  // ── p2pConnect 实验 ──

  /**
   * 发起标准 P2P 连接（实验用）。
   * 配置由实验分区人工输入/预设填充；调用为异步生效，最终结果由
   * p2pConnectionChange 事件与群组/网络快照观察，本方法仅返回发起结果。
   * 本机已是 GO 时系统会报错（GO 不能主动发起连接），原样文本化上抛。
   */
  p2pConnect(config: P2pConnectConfigView): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        let wifiConfig: wifiManager.WifiP2PConfig = {
          deviceAddress: config.deviceAddress,
          deviceAddressType: config.deviceAddressType,
          netId: config.netId,
          passphrase: config.passphrase,
          groupName: config.groupName,
          goBand: config.goBand
        };
        wifiManager.p2pConnect(wifiConfig);
        resolve('p2pConnect 已发起，等待 p2pConnectionChange 事件与网络快照确认结果');
      } catch (e) {
        reject('p2pConnect 发起异常: ' + errorText(e));
      }
    });
  }

  /** 中止进行中的 P2P 连接（连接卡住时的退出手段） */
  p2pCancelConnect(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        wifiManager.p2pCancelConnect();
        resolve('p2pCancelConnect 调用成功');
      } catch (e) {
        reject('p2pCancelConnect 调用异常: ' + errorText(e));
      }
    });
  }

  /**
   * 列出系统全部网络及接口名/链路地址（判定 P2P 网络是否注册到系统网络列表）。
   * 单条网络属性查询失败时该条显示「属性查询失败」，不影响其余条目。
   */
  listNetworks(): Promise<Array<NetworkListEntry>> {
    return new Promise<Array<NetworkListEntry>>((resolve, reject) => {
      connection.getAllNets()
        .then((nets: Array<connection.NetHandle>) => {
          let entries: Array<NetworkListEntry> = [];
          if (nets.length === 0) {
            resolve(entries);
            return;
          }
          let pending = nets.length;
          for (let i = 0; i < nets.length; i++) {
            let net = nets[i];
            connection.getConnectionProperties(net)
              .then((props: connection.ConnectionProperties) => {
                entries.push(this.toNetworkEntry(net, props));
                pending = pending - 1;
                if (pending === 0) {
                  resolve(entries);
                }
              })
              .catch(() => {
                let entry = new NetworkListEntry();
                entry.netId = net.netId;
                entry.interfaceName = '属性查询失败';
                entries.push(entry);
                pending = pending - 1;
                if (pending === 0) {
                  resolve(entries);
                }
              });
          }
        })
        .catch((e: BusinessError) => {
          reject('getAllNets 失败: ' + errorText(e));
        });
    });
  }

  /** 将 NetHandle + ConnectionProperties 聚合成网络列表条目 */
  private toNetworkEntry(net: connection.NetHandle, props: connection.ConnectionProperties): NetworkListEntry {
    let entry = new NetworkListEntry();
    entry.netId = net.netId;
    let iface = props.interfaceName;
    entry.interfaceName = iface === undefined ? '' : iface;
    let addrs: Array<string> = [];
    let la = props.linkAddresses;
    if (la !== undefined) {
      for (let j = 0; j < la.length; j++) {
        let a = la[j].address;
        if (a !== undefined && a.address.length > 0) {
          addrs.push(a.address);
        }
      }
    }
    entry.addresses = addrs;
    entry.isLikelyP2p = this.isP2pLike(entry);
    return entry;
  }

  /** 判断网络是否疑似 P2P：接口名含 p2p，或链路地址落在 MTA 默认 GO 网段 192.168.49.x */
  private isP2pLike(entry: NetworkListEntry): boolean {
    let iface = entry.interfaceName;
    if (iface.length > 0 && iface.toLowerCase().includes('p2p')) {
      return true;
    }
    for (let j = 0; j < entry.addresses.length; j++) {
      if (entry.addresses[j].startsWith('192.168.49.')) {
        return true;
      }
    }
    return false;
  }

  /**
   * TCP 可达性探测：连接指定 IP:端口，成功后立即关闭。
   * 默认 5 秒超时；失败/超时返回失败原因，不抛出（探测结果即数据面可用性判据）。
   */
  probeTcp(ip: string, port: number): Promise<TcpProbeResult> {
    return new Promise<TcpProbeResult>((resolve) => {
      let client = socket.constructTCPSocketInstance();
      let targetText = `${ip}:${port}`;
      let startMs = Date.now();
      let connectOpts: socket.TCPConnectOptions = {
        address: {
          address: ip,
          port: port,
          family: 1
        },
        timeout: 5000
      };
      client.connect(connectOpts)
        .then(() => {
          let result = new TcpProbeResult();
          result.targetText = targetText;
          result.ok = true;
          result.costMs = Date.now() - startMs;
          result.detail = `连接成功，耗时 ${result.costMs}ms`;
          client.close().catch(() => {
          });
          resolve(result);
        })
        .catch((e: BusinessError) => {
          let result = new TcpProbeResult();
          result.targetText = targetText;
          result.ok = false;
          result.costMs = Date.now() - startMs;
          result.detail = '连接失败: ' + probeErrorText(e);
          client.close().catch(() => {
          });
          resolve(result);
        });
    });
  }

  // ── P2P 设备发现 ──

  /** 开始 P2P 设备发现（防重入由调用方控制） */
  startDiscovery(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        wifiManager.startDiscoverDevices();
        resolve('startDiscoverDevices 调用成功');
      } catch (e) {
        reject('startDiscoverDevices 失败: ' + errorText(e));
      }
    });
  }

  /** 停止 P2P 设备发现 */
  stopDiscovery(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        wifiManager.stopDiscoverDevices();
        resolve('stopDiscoverDevices 调用成功');
      } catch (e) {
        reject('stopDiscoverDevices 失败: ' + errorText(e));
      }
    });
  }

  /** 注册 p2pPeerDeviceChange 事件，将系统设备列表映射为视图列表；注册失败不抛出 */
  registerDiscoveryEvents(handler: (devices: Array<P2pDiscoveredDeviceView>) => void): void {
    try {
      wifiManager.on('p2pPeerDeviceChange', (devices: Array<wifiManager.WifiP2pDevice>) => {
        let views: Array<P2pDiscoveredDeviceView> = [];
        if (devices !== undefined) {
          for (let i = 0; i < devices.length; i++) {
            let d = devices[i];
            if (d === undefined || d.deviceAddress === undefined || d.deviceAddress.length === 0) {
              continue;
            }
            let view = new P2pDiscoveredDeviceView();
            view.deviceName = d.deviceName === undefined ? '' : d.deviceName;
            view.deviceAddress = d.deviceAddress;
            // 地址类型原样取系统返回值（未返回时按真实地址兜底），连接时回传避免类型错配
            view.deviceAddressType = d.deviceAddressType === undefined ? 1 : d.deviceAddressType;
            views.push(view);
          }
        }
        handler(views);
      });
      this.discoveryHandler = handler;
    } catch (e) {
      this.discoveryHandler = null;
      logger.warn('P2P: p2pPeerDeviceChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册 p2pPeerDeviceChange 事件 */
  unregisterDiscoveryEvents(): void {
    this.discoveryHandler = null;
    try {
      wifiManager.off('p2pPeerDeviceChange');
    } catch (e) {
      logger.warn('P2P: p2pPeerDeviceChange 反注册失败: ' + errorText(e));
    }
  }

  // ── 定位权限（P2P 设备发现需要） ──

  /** 申请定位权限（APPROXIMATELY_LOCATION，user_grant），返回是否授予 */
  ensureLocationPermission(context: common.Context): Promise<boolean> {
    return new Promise<boolean>((resolve, reject) => {
      try {
        let atManager = abilityAccessCtrl.createAtManager();
        let permissions: Array<Permissions> = ['ohos.permission.APPROXIMATELY_LOCATION'];
        atManager.requestPermissionsFromUser(context, permissions)
          .then((result: PermissionRequestResult) => {
            let granted = result.authResults.length > 0 && result.authResults[0] === 0;
            resolve(granted);
          })
          .catch((e: BusinessError) => {
            reject(errorText(e));
          });
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  // ── 网络状态快照 ──

  /** 聚合 getIpInfo 与 getP2pLinkedInfo 为网络快照 */
  getNetworkSnapshot(): Promise<NetworkSnapshot> {
    return new Promise<NetworkSnapshot>((resolve, reject) => {
      let snapshot = new NetworkSnapshot();
      snapshot.snapshotTime = formatTimeText(new Date());
      try {
        let ipInfo = wifiManager.getIpInfo();
        snapshot.ipAddressText = numberIpToText(ipInfo.ipAddress);
        snapshot.gatewayText = numberIpToText(ipInfo.gateway);
        snapshot.netmaskText = numberIpToText(ipInfo.netmask);
      } catch (e) {
        reject('getIpInfo 失败: ' + errorText(e));
        return;
      }
      try {
        wifiManager.getP2pLinkedInfo()
          .then((linked: wifiManager.WifiP2pLinkedInfo) => {
            snapshot.p2pConnectStateText = connectStateText(linked.connectState);
            snapshot.isGroupOwner = linked.isGroupOwner;
            snapshot.groupOwnerAddr = linked.groupOwnerAddr;
            resolve(snapshot);
          })
          .catch((e: BusinessError) => {
            snapshot.p2pConnectStateText = '查询失败: ' + errorText(e);
            resolve(snapshot);
          });
      } catch (e) {
        snapshot.p2pConnectStateText = '查询异常: ' + errorText(e);
        resolve(snapshot);
      }
    });
  }

  // ── HTTP 服务与请求 ──

  /**
   * 启动极简 HTTP 服务（TCPSocketServer，收到请求即回固定文本）。
   * 优先绑定指定地址（GO IP），失败回退 0.0.0.0 并说明。
   */
  startHttpServer(bindIp: string, port: number): Promise<HttpServerState> {
    return new Promise<HttpServerState>((resolve, reject) => {
      if (this.tcpServer !== null) {
        reject('HTTP 服务已在运行，请先停止');
        return;
      }
      let server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      let state = new HttpServerState();
      let tryListen = (address: string): Promise<void> => {
        let listenAddr: socket.NetAddress = {
          address: address,
          port: port,
          family: 1
        };
        return server.listen(listenAddr);
      };
      tryListen(bindIp)
        .catch(() => {
          // 指定地址（P2P 接口）绑定失败，回退 0.0.0.0 并记录
          return tryListen('0.0.0.0');
        })
        .then(() => {
          this.tcpServer = server;
          state.running = true;
          state.bindAddress = bindIp;
          state.port = port;
          state.requestCount = 0;
          server.on('connect', (client: socket.TCPSocketConnection) => {
            client.on('message', (msgInfo: socket.SocketMessageInfo) => {
              state.requestCount = state.requestCount + 1;
              let resp = buildHttpResponse();
              let sendOpts: socket.TCPSendOptions = {
                data: resp
              };
              client.send(sendOpts).catch(() => {
              });
            });
          });
          resolve(state);
        })
        .catch((e: BusinessError) => {
          reject('HTTP 服务启动失败: ' + errorText(e));
        });
    });
  }

  /** 停止 HTTP 服务并释放资源 */
  stopHttpServer(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      if (this.tcpServer === null) {
        resolve('HTTP 服务未在运行');
        return;
      }
      let server = this.tcpServer;
      this.tcpServer = null;
      try {
        server.off('connect');
      } catch (e) {
        logger.warn('服务器: HTTP 服务 off(connect) 异常: ' + errorText(e));
      }
      server.close()
        .then(() => {
          resolve('HTTP 服务已停止');
        })
        .catch((e: BusinessError) => {
          reject('HTTP 服务关闭失败: ' + errorText(e));
        });
    });
  }

  /** 向指定 URL 发起 HTTP GET 请求，返回响应摘要或失败原因 */
  httpGet(url: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let httpRequest = http.createHttp();
      httpRequest.request(url, { method: http.RequestMethod.GET })
        .then((resp: http.HttpResponse) => {
          let code = resp.responseCode;
          let body = typeof resp.result === 'string' ? resp.result as string : '';
          let summary = body.length > 80 ? body.substring(0, 80) + '...' : body;
          resolve(`HTTP ${code} 响应: ${summary}`);
        })
        .catch((e: BusinessError) => {
          reject('HTTP 请求失败: ' + errorText(e));
        })
        .finally(() => {
          httpRequest.destroy();
        });
    });
  }
}

/** 构造固定文本的 HTTP 响应（内容长度按 UTF-8 字节数计算） */
function buildHttpResponse(): ArrayBuffer {
  let body = '<html><head><title>HandySend P2P Verify</title></head>' +
    '<body><h1>MTA P2P Verify Server OK</h1>' +
    '<p>本页面由 HandySend P2P 验证页的极简 HTTP 服务返回</p></body></html>';
  let encoder = new util.TextEncoder();
  let contentBuf = encoder.encodeInto(body);
  let header = 'HTTP/1.1 200 OK\r\n' +
    'Content-Type: text/html; charset=utf-8\r\n' +
    `Content-Length: ${contentBuf.byteLength}\r\n` +
    'Connection: close\r\n' +
    '\r\n';
  let headerBuf = encoder.encodeInto(header);
  let total = new ArrayBuffer(headerBuf.byteLength + contentBuf.byteLength);
  let totalView = new Uint8Array(total);
  totalView.set(new Uint8Array(headerBuf), 0);
  totalView.set(new Uint8Array(contentBuf), headerBuf.byteLength);
  return total;
}
