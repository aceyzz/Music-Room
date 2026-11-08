import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/features/event/data/event_source.dart';

import '../home/fake_home_apis.dart' as home;

/// In-memory [EventInfoApi]. Answers with [eventSummary], [queued] and
/// [guestList]; throws [failure] from every call.
class FakeEventInfoApi implements EventInfoApi {
  EventSummary eventSummary = home.event('e1');
  List<QueueEntry> queued = const [];
  List<EventMember> guestList = const [];
  AppError? failure;

  void _fail() {
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<EventSummary> event(String eventPublicId, String viewerPublicId) async {
    _fail();
    return eventSummary;
  }

  @override
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId) async {
    _fail();
    return queued;
  }

  @override
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId) async {
    _fail();
    return guestList;
  }
}
