import 'package:matrix_rest_api/matrix_client_api_r0.dart';
class RoomSummaryUtil {
  static Set<String> extractHeroIds(Iterable<RoomSummary> roomSummaries) {
    return roomSummaries.where((s) => s.m_heroes != null && s.m_heroes.isNotEmpty).expand((s) => s.m_heroes).toSet();
  }
}
