import MimeUtilsTest from './MimeUtils.test';
import ThemeStylesTest from './ThemeStyles.test';
import PreferencesUtilTest from './PreferencesUtil.test';
import FavoritesServiceTest from './FavoritesService.test';
import ReceiveHistoryServiceTest from './ReceiveHistoryService.test';

export default function testsuite() {
  MimeUtilsTest()
  ThemeStylesTest()
  PreferencesUtilTest()
  FavoritesServiceTest()
  ReceiveHistoryServiceTest()
}
