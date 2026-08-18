import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSize } from '../utils/FormatUtil';

// Item-level ViewModel wrapping a single receive-history entry.
// Chosen per the scenario-based list policy (Option B): entries are
// modifiable (deletable), so each item is wrapped instead of exposing
// the raw DTO to the view.
@Observed
export class ReceiveHistoryItemViewModel {
  public id: string = ''
  public fileName: string = ''
  public senderAlias: string = ''
  public fileSize: number = 0
  public savedToGallery: boolean = false
  public isMessage: boolean = false
  public timestamp: number = 0

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
