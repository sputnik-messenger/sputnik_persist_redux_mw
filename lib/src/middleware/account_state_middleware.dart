import 'package:built_collection/built_collection.dart';
import 'package:flutter/foundation.dart';
import 'package:redux/redux.dart';
import 'package:matrix_rest_api/matrix_client_api_r0.dart';
import 'package:sputnik_app_state/sputnik_app_state.dart';
import 'package:sputnik_persist_redux_mw/src/util/room_summary_util.dart';
import 'package:sputnik_persistence/sputnik_persistence.dart';
import 'package:sputnik_redux_store/sputnik_redux_store.dart';
import 'package:sputnik_redux_store/util.dart';

class AccountStateMiddleware extends MiddlewareClass<SputnikAppState> {
  Map<String, MatrixAccountDatabase> databases;

  AccountStateMiddleware(this.databases);

  @override
  void call(Store<SputnikAppState> store, action, NextDispatcher next) {
    if (action is OnSyncResponse) {
      final sw = Stopwatch()..start();

      final database = databases[action.userId];
      final roomSummaryBatch = database.roomSummaryProvider.batch;
      final roomEventBatch = database.roomEventProvider.batch;
      final userSummaryBatch = database.userSummaryProvider.batch;

      action.syncResponse.rooms.join.forEach((roomId, room) {
        final allStates = [
          ...room.state.events,
          ...room.timeline.events.where((event) => event.isStateEvent),
        ];

        batchWriteTimelineUpdates(
          roomSummaryBatch,
          roomEventBatch,
          userSummaryBatch,
          roomId,
          room.timeline.prev_batch,
          allStates,
          room.timeline.events,
        );

        handleRedactions(database, store, roomEventBatch, roomId, room.timeline.events.where((e) => e.redacts != null));

        final lastRelevantRoomEvent = room.timeline.events.lastWhere((e) => e.type == 'm.room.message', orElse: () => null);
        if (lastRelevantRoomEvent != null) {
          roomSummaryBatch.updateLastRelevantRoomEvent(roomId, lastRelevantRoomEvent);
        }

        roomSummaryBatch.updateUnreadNotificationCounts(roomId, room.unread_notifications);

        RoomSummary newRoomSummary = room.summary;
        final RoomSummary oldRoomSummary = store.state.accountStates[action.userId]?.roomSummaries[roomId]?.roomSummary;
        if (oldRoomSummary != null) {
          newRoomSummary = oldRoomSummary.merge(newRoomSummary);
        }
        if (oldRoomSummary != newRoomSummary) {
          roomSummaryBatch.updateMatrixRoomSummary(roomId, room.summary);
        }
      });
      action.syncResponse.rooms.leave.forEach((roomId, leftRoom) {
        roomEventBatch.deleteAllForRoom(roomId);
        roomSummaryBatch.delete(roomId);
      });

      roomSummaryBatch.commit(noResult: true);
      roomEventBatch.commit(noResult: true);
      debugPrint('middleware sync response ${sw.elapsedMilliseconds}ms');
      action.syncResponse.rooms.join.forEach((String roomId, JoinedRoom room) {
        final loadedRoom = store.state.accountStates[action.userId]?.roomStates[roomId];
        if (loadedRoom != null) {
          loadMissingUserSummariesFromDb(
            store,
            action.userId,
            roomId,
            room.timeline.events,
            loadedRoom.roomMembers,
          );
        }
      });
      userSummaryBatch.commit(noResult: true);

      final updatedSummaries = action.syncResponse.rooms.join.values.map((room) => room.summary).where((s) => s != null).toList();
      if (updatedSummaries.isNotEmpty) {
        loadMissingHeroUserSummariesFromDb(store, action.userId, updatedSummaries, store.state.accountStates[action.userId].heroes);
      }

      store.dispatch(OnSyncSuccess(action.userId, action.syncResponse.next_batch));
    } else if (action is OnRoomMessagesResponse) {
      final roomSummaryBatch = databases[action.userId].roomSummaryProvider.batch;
      final roomEventBatch = databases[action.userId].roomEventProvider.batch;
      final memberSummaryBatch = databases[action.userId].userSummaryProvider.batch;

      batchWriteTimelineUpdates(
        roomSummaryBatch,
        roomEventBatch,
        memberSummaryBatch,
        action.roomId,
        action.roomMessagesResponse.end,
        action.roomMessagesResponse.state ?? const [],
        action.roomMessagesResponse.chunk,
      );

      roomSummaryBatch.commit(noResult: true);
      roomEventBatch.commit(noResult: true);
      memberSummaryBatch.commit(noResult: true);

      final loadedRoom = store.state.accountStates[action.userId]?.roomStates[action.roomId];
      if (loadedRoom != null) {
        loadMissingUserSummariesFromDb(
          store,
          action.userId,
          action.roomId,
          action.roomMessagesResponse.chunk,
          loadedRoom.roomMembers,
        );
      }
    }
    next(action);
  }

  static batchWriteTimelineUpdates(
    RoomSummaryBatchWriter roomSummaryBatch,
    RoomEventBatchWriter roomEventBatch,
    UserSummaryBatchWriter userSummaryBatch,
    String roomId,
    String previousBatchToken,
    Iterable<RoomEvent> stateEvents,
    Iterable<RoomEvent> timeline,
  ) {
    batchWriteStateUpdates(roomSummaryBatch, userSummaryBatch, roomId, stateEvents);

    roomEventBatch.insertRoomEvents(roomId, timeline);

    roomSummaryBatch.updatePreviousBatchToken(
      roomId,
      previousBatchToken,
    );
  }

  static Future<void> handleRedactions(
    MatrixAccountDatabase database,
    Store<SputnikAppState> store,
    RoomEventBatchWriter batch,
    String roomId,
    Iterable<RoomEvent> redactions,
  ) async {
    final redactedEventIds = redactions.map((r) => r.redacts);
    final redactedEvents = await database.roomEventProvider.getRoomEventsFor(roomId, redactedEventIds);
    final redactedEventMap = Map<String, RoomEvent>.fromIterable(redactedEvents, key: (e) => e.event_id);
    for (RoomEvent redaction in redactions) {
      final toRedact = redactedEventMap[redaction.redacts];
      if (toRedact != null) {
        batch.insertRoomEvent(roomId, RedactionUtil.redact(toRedact, redaction));
      }
    }
  }

  static batchWriteStateUpdates(
    RoomSummaryBatchWriter roomSummaryBatch,
    UserSummaryBatchWriter userSummaryBatch,
    String roomId,
    Iterable<RoomEvent> stateEvents,
  ) {
    final util = SupportedStateEventUtil();
    final createEvent = stateEvents.firstWhere((e) => e.type == util.types.create, orElse: () => null);
    if (createEvent != null) {
      final createStateEvent = StateEventBuilder<CreateContent>()
        ..roomEvent = createEvent
        ..content = CreateContent.fromJson(createEvent.content);
      final roomStateValues = RoomStateValuesBuilder()..create = createStateEvent;
      final newRoomSummary = ExtendedRoomSummaryBuilder()
        ..roomId = roomId
        ..roomStateValues = roomStateValues
        ..roomSummary = RoomSummary();
      debugPrint('new room: $roomId');
      roomSummaryBatch.insertRoomSummary(newRoomSummary.build());
    }

    stateEvents.forEach((event) {
      final typeEnum = util.typeEnumFrom(event.type);
      switch (typeEnum) {
        case SupportedStateEventEnum.create:
          // is handled above
          break;
        case SupportedStateEventEnum.name:
          roomSummaryBatch.updateName(roomId, event);
          break;
        case SupportedStateEventEnum.topic:
          roomSummaryBatch.updateTopic(roomId, event);
          break;
        case SupportedStateEventEnum.avatar:
          roomSummaryBatch.updateAvatar(roomId, event);
          break;
        case SupportedStateEventEnum.tombstone:
          roomSummaryBatch.updateTombstone(roomId, event);
          break;
        case SupportedStateEventEnum.member:
          final memberContent = MemberContent.fromJson(event.content);

          debugPrint('member event for ${event.state_key}: name ${memberContent.displayname}');
          userSummaryBatch.upsertUserSummary(UserSummary((b) {
            b.userId = event.state_key;
            if (memberContent.displayname != null) {
              b.displayName = TimestampedBuilder<String>()
                ..value = memberContent.displayname
                ..timestamp = event.origin_server_ts;
              debugPrint('upsert ${b.userId} => ${b.displayName.value}');
            }
            if (memberContent.avatar_url != null) {
              b.avatarUrl = TimestampedBuilder<String>()
                ..value = memberContent.avatar_url
                ..timestamp = event.origin_server_ts;
            }
          }));

          break;
        case SupportedStateEventEnum.aliases:
        case SupportedStateEventEnum.canonical_alias:
        case SupportedStateEventEnum.join_rule:
        case SupportedStateEventEnum.encryption:
        case SupportedStateEventEnum.power_levels:
        case SupportedStateEventEnum.redaction:
        case SupportedStateEventEnum.history_visibility:
        case SupportedStateEventEnum.guest_access:
          // TODO: Handle these cases.
          break;
      }
    });
  }

  Future<void> loadMissingUserSummariesFromDb(
    Store<SputnikAppState> store,
    String userId,
    String roomId,
    List<RoomEvent> events,
    BuiltMap<String, UserSummary> knownUserSummaries,
  ) async {
    if (events.isNotEmpty) {
      final missing = events.where((e) => !knownUserSummaries.containsKey(e)).map((e) => e.sender).toSet();
      if (missing.isNotEmpty) {
        final userSummaries = await databases[userId].userSummaryProvider.getUserSummariesFor(missing);
        if (userSummaries.isNotEmpty) {
          store.dispatch(OnLoadedUserSummariesFromDb(userId, roomId, Map<String, UserSummary>.fromIterable(userSummaries, key: (u) => u.userId)));
        }
      }
    }
  }

  Future<void> loadMissingHeroUserSummariesFromDb(
    Store<SputnikAppState> store,
    String userId,
    List<RoomSummary> changedRoomSummaries,
    BuiltMap<String, UserSummary> knownHeroes,
  ) async {
    if (changedRoomSummaries.isNotEmpty) {
      final changedHeroIds = RoomSummaryUtil.extractHeroIds(changedRoomSummaries);

      final missing = changedHeroIds.where((e) => !knownHeroes.containsKey(e));
      if (missing.isNotEmpty) {
        final userSummaries = await databases[userId].userSummaryProvider.getUserSummariesFor(missing);
        if (userSummaries.isNotEmpty) {
          store.dispatch(OnLoadedHeroUserSummariesFromDb(userId, Map<String, UserSummary>.fromIterable(userSummaries, key: (u) => u.userId)));
        }
      }
    }
  }
}
