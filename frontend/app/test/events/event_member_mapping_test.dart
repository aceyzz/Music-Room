import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/gen/music_room/v1/dto/event.pb.dart';

void main() {
  String media(String key) => 'http://media.test/$key';

  test('a member carries the public id that opens their profile, and their picture', () {
    final member = EventMemberDTO(
      userId: Int64(7),
      userPublicId: 'u-7',
      displayName: 'Trinity',
      role: 'viewer',
      avatarStorageKey: 'avatars/7.png',
    ).toMember(mediaUrl: media);

    expect(member.publicId, 'u-7');
    expect(member.avatarUrl, 'http://media.test/avatars/7.png');
  });

  test('no picture and no public id read as null', () {
    final member = EventMemberDTO(displayName: 'Neo', role: 'viewer').toMember(mediaUrl: media);

    expect(member.publicId, isNull);
    expect(member.avatarUrl, isNull);
  });
}
