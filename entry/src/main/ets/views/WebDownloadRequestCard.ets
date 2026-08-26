import { HdsListItemCard, PrefixIcon, IconSize, SuffixSubIcon } from '@kit.UIDesignKit';
import { DesignTokens } from '../common/DesignTokens';
import { PendingWebDownload } from '../viewmodel/ShareLinkViewModel';

/**
 * WebDownloadRequestCard
 * 展示单条待确认的 Web 传输请求（来源 IP），提供"接受"和"拒绝"两个图标按钮。
 * 使用 HdsListItemCard 组件，仿照设备列表风格。
 * - A 区：下载/上传图标（根据 isReceiveMode 切换）
 * - B 区：primaryText = 来源 IP，secondaryText = "来自"
 * - C 区：SuffixSubIcon 放拒绝(xmark) + 接受(checkmark) 两个图标按钮
 * 操作回调上抛给父组件（Page/ViewModel 持有业务逻辑）。
 */
@ComponentV2
export struct WebDownloadRequestCard {
  @Param request: PendingWebDownload = {
    sessionId: '',
    ip: '',
    timestamp: 0
  }
  @Param isReceiveMode: boolean = false
  @Event onAccept: (sessionId: string) => void = (_sessionId: string) => {
  }
  @Event onDecline: (sessionId: string) => void = (_sessionId: string) => {
  }

  build() {
    Row() {
      HdsListItemCard({
        prefixItem: new PrefixIcon({
          iconSize: IconSize.SYSTEM_ICON,
          iconValue: {
            // 接收模式：别人上传到本机 → arrow_up_circle；分享模式：别人从本机下载 → arrow_down_circle
            symbol: this.isReceiveMode ? $r('sys.symbol.arrow_up_circle') : $r('sys.symbol.arrow_down_circle')
          }
        }),
        textItem: {
          primaryText: {
            text: this.request.ip
          },
          secondaryText: {
            text: $r('app.string.web_download_from')
          }
        },
        suffixItem: new SuffixSubIcon(
          // 第一个图标：拒绝（xmark）
          {
            iconValue: {
              symbol: $r('sys.symbol.xmark')
            },
            onClick: () => {
              this.onDecline(this.request.sessionId);
            }
          },
          // 第二个图标：接受（checkmark）
          {
            iconValue: {
              symbol: $r('sys.symbol.checkmark')
            },
            onClick: () => {
              this.onAccept(this.request.sessionId);
            }
          }
        ),
        // 仿照设备列表配色：page_background + md 圆角
        cardBackgroundColor: $r('app.color.page_background'),
        cardBorderRadius: DesignTokens.radius.md,
        cardPrefixMargin: 0,
        cardSuffixMargin: 0
      })
    }
    .width('100%')
  }
}
