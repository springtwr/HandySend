/**
 * MtaConstants.ets — MTA 接收端协议常量
 *
 * 集中定义 MTA 协议涉及的全部常量：BLE 广播/GATT UUID、WebSocket 与下载路径、
 * 协议版本、WiFi Direct 默认网关、AES 参数、超时与安全上限。
 * 数值逐字节对齐 docs/mta 逆向结论，禁止在此之外散落魔法值。
 */

export class MtaConstants {
  // ── BLE 广播 ──

  /** 广播主 serviceUuid（MTA 发现标识，非标准基址 ...008123456789） */
  static readonly ADV_SERVICE_UUID: string = '00003331-0000-1000-8000-008123456789';
  /** 主广播 serviceData UUID（6 字节：2B 发送者 ID + 4B 零） */
  static readonly ADV_DATA_UUID: string = '000001ff-0000-1000-8000-00805f9b34fb';
  /** 扫描响应 serviceData UUID（27 字节：零填充 + 发送者 ID + 设备名 + 0x01） */
  static readonly SCAN_RSP_UUID: string = '0000ffff-0000-1000-8000-00805f9b34fb';
  /** 主广播 serviceData 长度（字节） */
  static readonly ADV_DATA_LENGTH: number = 6;
  /** 扫描响应 serviceData 长度（字节） */
  static readonly SCAN_RSP_LENGTH: number = 27;
  /** 扫描响应中设备名字段起始偏移 */
  static readonly SCAN_RSP_NAME_OFFSET: number = 10;
  /** 扫描响应中设备名字段长度（字节） */
  static readonly SCAN_RSP_NAME_LENGTH: number = 16;
  /** 发送者 ID 长度（字节） */
  static readonly SENDER_ID_LENGTH: number = 2;
  /** 设备名 UTF-8 最大字节数 */
  static readonly DEVICE_NAME_MAX_BYTES: number = 15;
  /** 扫描响应设备名尾部填充字符（\t） */
  static readonly NAME_FIELD_PADDING: number = 0x09;
  /** 扫描响应末字节标记 */
  static readonly SCAN_RSP_TAIL_FLAG: number = 0x01;

  // ── GATT 凭据通道 ──

  /** GATT 服务 UUID */
  static readonly GATT_SERVICE_UUID: string = '00009955-0000-1000-8000-00805f9b34fb';
  /** CHAR_STATUS 特征 UUID（读 → DeviceInfo JSON） */
  static readonly CHAR_STATUS_UUID: string = '00009954-0000-1000-8000-00805f9b34fb';
  /** CHAR_P2P 特征 UUID（写 → P2pInfo JSON） */
  static readonly CHAR_P2P_UUID: string = '00009953-0000-1000-8000-00805f9b34fb';
  /** prepared write 会话缓冲上限（字节） */
  static readonly MAX_WRITE_BUFFER: number = 4096;
  /** DeviceInfo 兜底蓝牙 MAC（三方应用无法获取可靠真实蓝牙 MAC） */
  static readonly FALLBACK_MAC: string = '02:00:00:00:00:00';
  /** DeviceInfo.catShare 版本标识（CatShare 惯例值） */
  static readonly CATSHARE_VERSION: number = 7;
  /** DeviceInfo.state 固定值 */
  static readonly DEVICE_INFO_STATE: number = 0;

  // ── 加解密 ──

  /** ECDH 曲线算法名 */
  static readonly ECC_ALGORITHM: string = 'ECC256';
  /** AES 算法名（AES-256-CTR，无填充） */
  static readonly AES_ALGORITHM: string = 'AES256|CTR|NoPadding';
  /** AES 对称密钥生成器算法名 */
  static readonly AES_SYM_ALGORITHM: string = 'AES256';
  /** AES 固定 IV 文本（16 字节 ASCII，非 8 字节） */
  static readonly AES_IV_TEXT: string = '0102030405060708';
  /** 共享密钥期望长度（字节，ECDH P-256 X 坐标） */
  static readonly SHARED_KEY_LENGTH: number = 32;

  // ── 网络端点 ──

  /** WebSocket 路径 */
  static readonly WS_PATH: string = '/websocket';
  /** 下载路径前缀（追加 taskId 查询参数） */
  static readonly DOWNLOAD_PATH: string = '/download?taskId=';
  /** WiFi Direct 默认 GO 网关地址（获取失败时兜底） */
  static readonly DEFAULT_GO_IP: string = '192.168.49.1';
  /** P2pInfo 未提供端口时的兜底端口 */
  static readonly DEFAULT_TRANSFER_PORT: number = 43210;

  // ── WS 应用层协议 ──

  /** 协议版本 */
  static readonly PROTOCOL_VERSION: number = 1;
  /** catShareText 随 sendRequest 走 WS 单帧传输的字节上限（超大文本仍可经 ZIP 文件条目完整发送） */
  static readonly MAX_SHARE_TEXT_BYTES: number = 256 * 1024;
  /** 协商 ack 中声明的线程上限 */
  static readonly THREAD_LIMIT: number = 5;
  /** 接收端主动消息 ID 起始值（CatShare status 固定 99） */
  static readonly STATUS_MESSAGE_ID: number = 99;
  /** status 成功类型 */
  static readonly STATUS_TYPE_OK: number = 1;
  /** status 拒绝类型 */
  static readonly STATUS_TYPE_REFUSE: number = 3;
  /** status 成功原因文本 */
  static readonly STATUS_REASON_OK: string = 'ok';
  /** status 拒绝原因文本 */
  static readonly STATUS_REASON_REFUSE: string = 'user refuse';
  /** 回送成功状态后等待发送方收尾的时间（毫秒，CatShare 收到后约 1s 删组停服） */
  static readonly STATUS_SETTLE_DELAY_MS: number = 1500;

  // ── 超时与安全上限 ──

  /** P2P 连接等待超时（毫秒） */
  static readonly P2P_CONNECT_TIMEOUT_MS: number = 15000;
  /** P2P 连接确认轮询间隔（毫秒，凭据直连无可靠事件时兜底检测已连 SSID） */
  static readonly P2P_POLL_INTERVAL_MS: number = 500;
  /** P2P 网络绑定轮询次数上限（等待 P2P 网络出现） */
  static readonly P2P_BIND_MAX_POLLS: number = 10;
  /** P2P 网络绑定轮询间隔（毫秒） */
  static readonly P2P_BIND_POLL_INTERVAL_MS: number = 500;
  /** WS 单次连接等待超时（毫秒，短以便尽快重试） */
  static readonly WS_CONNECT_TIMEOUT_MS: number = 3000;
  /** WS 握手前 TCP 可达性预探测超时（毫秒） */
  static readonly WS_TCP_PROBE_TIMEOUT_MS: number = 5000;
  /** WS 连接前等待 P2P 网络就绪的时间（毫秒） */
  static readonly WS_SETTLE_DELAY_MS: number = 1000;
  /** WS 连接失败后的重试间隔（毫秒） */
  static readonly WS_RETRY_DELAY_MS: number = 800;
  /** WS 连接最大尝试次数 */
  static readonly WS_CONNECT_MAX_ATTEMPTS: number = 4;
  /** 版本协商完成后等待接收请求的超时（毫秒，对端静默失联时避免无限期卡死） */
  static readonly REQUEST_WAIT_TIMEOUT_MS: number = 30000;
  /** 下载连接超时（毫秒） */
  static readonly DOWNLOAD_CONNECT_TIMEOUT_MS: number = 30000;
  /** 下载读取超时（毫秒，0 表示不超时） */
  static readonly DOWNLOAD_READ_TIMEOUT_MS: number = 0;
  /** 解压后允许的总大小上限（字节，防 zip bomb） */
  static readonly MAX_UNZIP_TOTAL_BYTES: number = 2 * 1024 * 1024 * 1024;
  /** 解压后允许的条目数上限（防 zip bomb） */
  static readonly MAX_UNZIP_ENTRY_COUNT: number = 4096;

  // ── 发送端：GATT Client ──

  /** 发送端 GATT 连接等待超时（毫秒，含状态事件等待） */
  static readonly GATT_CONNECT_TIMEOUT_MS: number = 10000;
  /** 发送端读取对端 DeviceInfo 等待超时（毫秒） */
  static readonly GATT_READ_TIMEOUT_MS: number = 8000;
  /** 发送端等待 GATT 连接就绪的轮询间隔（毫秒） */
  static readonly GATT_CONNECT_POLL_MS: number = 200;
  /** 发送端写入 P2pInfo 后等待回调/返回超时（毫秒） */
  static readonly GATT_WRITE_TIMEOUT_MS: number = 8000;
  /** 发送端 GATT Client 请求协商的 MTU（字节；默认 23 单次仅可写 20 字节，不足以写入 P2pInfo） */
  static readonly GATT_MTU_SIZE: number = 512;
  /** BLE 未协商时的默认 MTU（字节） */
  static readonly BLE_DEFAULT_MTU: number = 23;
  /** 等待 MTU 协商完成的超时（毫秒） */
  static readonly GATT_MTU_TIMEOUT_MS: number = 3000;
  /** 等待 MTU 协商完成的轮询间隔（毫秒） */
  static readonly GATT_MTU_POLL_MS: number = 100;
  /** 发送端服务发现最大尝试次数（服务发现偶发失败时重试） */
  static readonly GATT_DISCOVERY_MAX_ATTEMPTS: number = 3;
  /** 发送端服务发现重试间隔（毫秒） */
  static readonly GATT_DISCOVERY_RETRY_DELAY_MS: number = 400;

  // ── 发送端：WiFi Direct 建组 ──

  /** 发送端建组后等待群组信息就绪超时（毫秒） */
  static readonly GROUP_READY_TIMEOUT_MS: number = 20000;
  /** 发送端轮询群组信息间隔（毫秒） */
  static readonly GROUP_POLL_INTERVAL_MS: number = 500;
  /** WiFi Direct 群组名前缀 */
  static readonly GROUP_NAME_PREFIX: string = 'DIRECT-';
  /** WiFi Direct 群组口令长度（字符） */
  static readonly GROUP_PASSPHRASE_LENGTH: number = 8;
  /** 群组信息查询"当前无群组"错误码 */
  static readonly GROUP_NOT_FOUND_CODE: number = 2801000;
  /** 群主频段：自动（对端支持 5GHz 时使用） */
  static readonly GROUP_OWNER_BAND_AUTO: number = 0;
  /** 群主频段：2.4GHz（对端不支持 5GHz 时使用） */
  static readonly GROUP_OWNER_BAND_2GHZ: number = 1;

  // ── 发送端：TLS 服务器 ──

  /** 发送端默认端口（0 = 由系统随机分配） */
  static readonly DEFAULT_SEND_PORT: number = 0;
  /** bindIp 绑定失败时的兜底绑定地址 */
  static readonly DEFAULT_BIND_IP: string = '0.0.0.0';
  /** 启动 Rust 服务器等待超时（毫秒） */
  static readonly SERVER_START_TIMEOUT_MS: number = 10000;
  /** P2pInfo 写回后等待对端 WS 连接的超时（毫秒，覆盖对端解密凭据、直连建组与 WS 握手重试链路的最大时长） */
  static readonly WAITING_WS_TIMEOUT_MS: number = 60000;

  // ── 发送端：WS 应用层消息 ID ──

  /** 发送端 versionNegotiation 消息 ID */
  static readonly WS_VERSION_NEGOTIATION_ID: number = 0;
  /** 发送端 sendRequest 消息 ID */
  static readonly WS_SEND_REQUEST_ID: number = 1;

  // ── 发送端：文件暂存与 ZIP ──

  /** 发送暂存目录名前缀（cacheDir/mta_send_<taskId>） */
  static readonly STAGE_DIR_PREFIX: string = 'mta_send_';
  /** 发送端 ZIP 输出文件名 */
  static readonly ZIP_FILE_NAME: string = 'files.zip';
  /** 发送端 ZIP 条目数上限 */
  static readonly MAX_SEND_ENTRY_COUNT: number = 4096;
  /** 发送端 ZIP 总大小上限（字节，与接收端口径一致） */
  static readonly MAX_SEND_TOTAL_BYTES: number = 2 * 1024 * 1024 * 1024;
  /** 发送进度节流间隔（毫秒） */
  static readonly PROGRESS_THROTTLE_MS: number = 200;

  // ── 发送端：品牌 / 会话 ──

  /** 第三方品牌 ID（P2pInfo/Broadcast 中的标识） */
  static readonly BRAND_ID_THIRD_PARTY: number = 0xff;
  /** 发送完成后延迟清理资源的等待时间（毫秒，给对端收尾时间） */
  static readonly SEND_COMPLETE_SETTLE_DELAY_MS: number = 3000;
  /** Rust 侧日志轮询间隔（毫秒，用于在发送页展示服务器/TLS/WS 诊断日志） */
  static readonly RUST_LOG_POLL_MS: number = 500;
  /** 等待对端入组时的群组客户端数轮询间隔（毫秒） */
  static readonly GROUP_CLIENT_POLL_MS: number = 1000;

  /**
   * 按品牌标识生成主广播 serviceData UUID：品牌字节取 brandId 低 8 位的两位小写十六进制。
   * 默认第三方（0xff）时返回值等于 ADV_DATA_UUID，保证零回归。
   */
  static mainAdvDataUuidForBrand(brandId: number): string {
    let hex = (brandId & 0xff).toString(16);
    let brandHex = hex.length === 1 ? '0' + hex : hex;
    // 复用主广播 UUID 的固定后缀，仅替换品牌字节段（前 8 字符为 `000001xx`）
    return `000001${brandHex}${MtaConstants.ADV_DATA_UUID.substring(8)}`;
  }

  /** 构造 AES 固定 IV 的字节数组（每次返回独立实例，避免被外部修改） */
  static aesIvBytes(): Uint8Array {
    let bytes = new Uint8Array(MtaConstants.AES_IV_TEXT.length);
    for (let i = 0; i < MtaConstants.AES_IV_TEXT.length; i++) {
      bytes[i] = MtaConstants.AES_IV_TEXT.charCodeAt(i);
    }
    return bytes;
  }
}
