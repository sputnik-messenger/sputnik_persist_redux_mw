
import 'package:sputnik_app_state/sputnik_app_state.dart';
import 'package:flutter/foundation.dart';
import 'package:redux/redux.dart';
import 'package:sputnik_persistence/sputnik_persistence.dart';
import 'package:sputnik_redux_store/sputnik_redux_store.dart';


class AppStateMiddleware extends MiddlewareClass<SputnikAppState> {
  final SputnikDatabase sputnikDatabase;

  AppStateMiddleware(this.sputnikDatabase);

  @override
  void call(Store<SputnikAppState> store, action, NextDispatcher next) {
    if (action is AddAccount) {
      debugPrint('AddAccount');
      sputnikDatabase.accountSummaryProvider.insertAccountSummary(action.accountSummary);
    } else if (action is RemoveAccount) {
      debugPrint('RemoveAccount');
      sputnikDatabase.accountSummaryProvider.deleteAccountSummary(action.userId);
      // todo: remove everything user related, db file, prefs, cache ...
    } else if (action is OnSyncSuccess) {
      sputnikDatabase.accountSummaryProvider.updateNextBatchSyncToken(action.userId, action.nextBatchSyncToken);
    }
    next(action);
  }
}
