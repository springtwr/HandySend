import MimeUtilsTest from './MimeUtils.test';
import PreferencesUtilTest from './PreferencesUtil.test';
import FavoritesServiceTest from './FavoritesService.test';
import ReceiveHistoryServiceTest from './ReceiveHistoryService.test';
import TransferProgressTest from './TransferProgress.test';

export default function testsuite() {
  MimeUtilsTest()
  PreferencesUtilTest()
  FavoritesServiceTest()
  ReceiveHistoryServiceTest()
  TransferProgressTest()
}
