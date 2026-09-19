/**
 * StatusBarPage.ets — 状态栏图标左键弹窗页（PC/2in1）
 *
 * 由 TrayPanelAbility（StatusBarViewExtensionAbility）加载，与主 UIAbility
 * 同进程运行，直接读取传输聚合快照单例并订阅 changeBus 实时刷新。
 * 渲染总体进度与单会话列表（方向/设备名/百分比）。
 */

import {
  gatherSessionSnapshots
} from '../service/BackgroundTransferService';
import {
  TransferDirection,
  TransferSessionSnapshot,
  OverallTransferSnapshot,
  computeOverallTransferSnapshot
} from '../utils/TransferProgressUtil';
import { subscribe, unsubscribe } from '../service/repository/AppCore';

// 会话行展示数据（@Local 状态需为可观察的普通对象）
@ObservedV2
class SessionRow {
  displayName: string = '';
  directionText: string = '';
  percent: number = 0;
  active: boolean = true;
}

@Entry
@ComponentV2
struct StatusBarPage {
  @Local overallPercent: number = 0;
  @Local hasActive: boolean = false;
  @Local rows: Array<SessionRow> = [];

  // changeBus 回调：重算聚合快照并刷新弹窗内容
  private refresh = (): void => {
    let snapshots = gatherSessionSnapshots();
    let overall: OverallTransferSnapshot = computeOverallTransferSnapshot(snapshots, 0);
    this.overallPercent = Math.floor(overall.percent);
    this.hasActive = overall.active;
    let nextRows: Array<SessionRow> = [];
    for (let i = 0; i < snapshots.length; i++) {
      let s = snapshots[i];
      let row = new SessionRow();
      row.displayName = s.displayName;
      row.directionText = this.directionText(s.direction);
      row.percent = s.totalBytes > 0 ? Math.floor(s.bytesSent * 100 / s.totalBytes) : 0;
      row.active = s.active;
      nextRows.push(row);
    }
    this.rows = nextRows;
  };

  // 方向前缀文案：发送「发送至」；接收（LocalSend/MTA）「来自」
  private directionText(direction: TransferDirection): string {
    let ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return '';
    }
    let resId: number = $r('app.string.transfer_direction_from').id;
    if (direction === TransferDirection.send) {
      resId = $r('app.string.transfer_direction_to').id;
    }
    // 前缀资源含 %s 占位，先以空参取出前缀部分
    return ctx.resourceManager.getStringSync(resId, '');
  }

  aboutToAppear(): void {
    this.refresh();
    subscribe(this.refresh);
  }

  aboutToDisappear(): void {
    unsubscribe(this.refresh);
  }

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.bg_transfer_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Progress({ value: this.overallPercent, total: 100, type: ProgressType.Linear })
        .height(6)
        .width('100%')
      Text(this.overallPercent + '%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
      if (this.rows.length > 0) {
        List({ space: 4 }) {
          ForEach(this.rows, (row: SessionRow) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(row.directionText + row.displayName)
                  .fontSize(12)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(row.percent + '%' + (row.active ? '' : ' ✓'))
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .width('100%')
            }
          }, (row: SessionRow) => row.displayName + '_' + row.percent.toString() + '_' + (row.active ? '1' : '0'))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)
  }
}
