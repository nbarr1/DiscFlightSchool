import '../../models/form_session_record.dart';

/// Persistence boundary for saved Form Coach session summaries.
abstract interface class FormHistoryRepository {
  Future<List<FormSessionRecord>> getSessions();
  Future<void> saveSession(FormSessionRecord session);
  Future<void> clearSessions();
  Future<List<FormSessionRecord>> trend(String throwType, {int limit = 10});
}
