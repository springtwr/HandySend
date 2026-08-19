import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSize } from '../utils/FormatUtil';

// Item-level ViewModel wrapping a single receive-history entry.
// Chosen per the scenario-based list policy (Option B): entries are
// modifiable (deletable), so each item is wrapped instead of exposing
// the raw DTO to the view.
@ObservedV2
export class ReceiveHistoryItemViewModel {
  @Trace public id: string = ''
  @Trace public fileName: string = ''
  @Trace public senderAlias: string = ''
  @Trace public fileSize: number = 0
  @Trace public savedToGallery: boolean = false
  @Trace public isMessage: boolean = false
  @Trace public timestamp: number = 0

  constructor(entry: ReceiveHistoryEntry) {
    this.id = entry.id;
    this.fileName = entry.fileName;
    this.senderAlias = entry.senderAlias;
    this.fileSize = entry.fileSize;
    this.savedToGallery = entry.savedToGallery;
    this.isMessage = entry.isMessage;
    this.timestamp = entry.timestamp;
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSize(this.fileSize);
  }
}
