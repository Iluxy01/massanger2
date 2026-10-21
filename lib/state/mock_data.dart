import '../models/models.dart';
import '../utils.dart';

/// Демо-друзья. На этапе бэкенда их заменят реальные контакты из локальной БД.
List<Contact> demoContacts() {
  final now = DateTime.now();
  return [
    Contact(
      id: 'alice',
      name: 'Алиса',
      emoji: '🦊',
      colorIndex: 0,
      fingerprint: randomHex(64),
      online: true,
      hasStory: true,
      verified: true,
      bio: 'кофе, код и котики',
    ),
    Contact(
      id: 'max',
      name: 'Макс',
      emoji: '🐺',
      colorIndex: 1,
      fingerprint: randomHex(64),
      online: true,
      hasStory: true,
      bio: 'катаюсь на борде 🏂',
    ),
    Contact(
      id: 'kate',
      name: 'Катя',
      emoji: '🌸',
      colorIndex: 6,
      fingerprint: randomHex(64),
      lastSeen: now.subtract(const Duration(minutes: 12)),
      hasStory: true,
      bio: 'фотографирую закаты',
    ),
    Contact(
      id: 'dima',
      name: 'Дима',
      emoji: '🎧',
      colorIndex: 5,
      fingerprint: randomHex(64),
      lastSeen: now.subtract(const Duration(hours: 3)),
      bio: 'музыка громче мыслей',
    ),
    Contact(
      id: 'sonya',
      name: 'Соня',
      emoji: '🌙',
      colorIndex: 4,
      fingerprint: randomHex(64),
      online: true,
      bio: 'сова 🦉',
    ),
    Contact(
      id: 'lev',
      name: 'Лёва',
      emoji: '🐙',
      colorIndex: 2,
      fingerprint: randomHex(64),
      lastSeen: now.subtract(const Duration(days: 2)),
      bio: 'пишу на Rust',
    ),
    Contact(
      id: 'tim',
      name: 'Тимур',
      emoji: '🚀',
      colorIndex: 3,
      fingerprint: randomHex(64),
      lastSeen: now.subtract(const Duration(days: 5)),
    ),
    Contact(id: demoGroupId, name: 'Поход на выходных', emoji: '🏕️', colorIndex: 2)
      ..group = GroupInfo(
        members: [
          GroupMember(pub: 'me', name: 'Я', emoji: '🐼', color: 1),
          GroupMember(pub: 'alice', name: 'Алиса', emoji: '🦊', color: 0),
          GroupMember(pub: 'max', name: 'Макс', emoji: '🐺', color: 1),
          GroupMember(pub: 'kate', name: 'Катя', emoji: '🌸', color: 6),
        ],
        admin: 'alice',
        ver: 1,
      ),
  ];
}

/// Демо-группа.
const demoGroupId = 'g_demo_trip';

Map<String, List<Message>> demoMessages() {
  final now = DateTime.now();
  var n = 0;
  Message m(
    bool mine,
    String text,
    Duration ago, {
    Message? reply,
    bool secret = false,
    MsgKind kind = MsgKind.text,
    int voice = 0,
    String? reaction,
    MsgStatus status = MsgStatus.read,
    Attachment? att,
    GeoPoint? geo,
    Poll? poll,
    String? from,
    String? ev,
  }) {
    return Message(
      from: from,
      ev: ev,
      att: att,
      geo: geo,
      poll: poll,
      id: 'seed${n++}',
      mine: mine,
      text: text,
      time: now.subtract(ago),
      replyTo: reply,
      secret: secret,
      kind: kind,
      voiceSeconds: voice,
      reaction: reaction,
      status: status,
    );
  }

  const sec = Duration(seconds: 1);
  const min = Duration(minutes: 1);
  const hour = Duration(hours: 1);
  const day = Duration(days: 1);

  final alicePlan = m(false, 'Го в субботу на крышу смотреть звёзды? ✨', day + hour * 2);
  final alice = [
    alicePlan,
    m(true, 'Да! Я возьму плед и термос', day + hour * 2 - min * 3, reaction: '❤️'),
    m(false, 'Идеально. Пароль от вайфая на даче скину тут', day + hour),
    m(false, 'cosmos_2024!', day + hour - min, secret: true),
    m(true, 'Удобно, что всё хранится только у нас на телефонах 😌', min * 40),
    m(false, '', min * 38, kind: MsgKind.voice, voice: 14),
    m(true, 'Так в субботу во сколько?', min * 6, reply: alicePlan),
    m(false, 'В 21:00, после заката 🌅', min * 2 + sec * 30),
    m(
      false,
      '',
      min * 2 + sec * 20,
      kind: MsgKind.geo,
      geo: const GeoPoint(55.7539, 37.6208, accuracy: 15),
    ),
    m(
      true,
      '',
      min * 2 + sec * 10,
      kind: MsgKind.poll,
      poll: Poll(
        question: 'Что берём на крышу?',
        options: ['Чай в термосе', 'Какао', 'Лимонад'],
        votes: {
          'alice': [1],
        },
      ),
    ),
    m(false, '🔥🔥', min * 1),
  ];

  final max = [
    m(false, 'Скинь трек, который вчера играл', hour * 5),
    m(true, 'Сейчас найду', hour * 5 - min * 2),
    m(true, '', hour * 4, kind: MsgKind.voice, voice: 23),
    m(false, 'Огонь 🤘', hour * 3, reaction: '🔥'),
    m(true, 'В пятницу в силу?', min * 25, status: MsgStatus.delivered),
  ];

  final kate = [
    m(true, 'Как прошла съёмка?', day * 2),
    m(false, 'Супер! Поймала тот самый розовый закат', day * 2 - hour),
    m(false, '🌅', day * 2 - hour),
    m(true, 'Покажешь?', day - hour * 3, status: MsgStatus.read),
    m(false, 'Завтра скину, обработаю только', hour * 2),
    m(
      false,
      'Тот самый закат',
      hour,
      kind: MsgKind.photo,
      att: Attachment(
        name: 'sunset.jpg',
        mime: 'image/jpeg',
        size: 842000,
        width: 1600,
        height: 1200,
        thumb: demoSunsetThumb,
      ),
    ),
    m(
      false,
      '',
      hour - min,
      kind: MsgKind.file,
      att: Attachment(name: 'Маршрут_поездки.pdf', mime: 'application/pdf', size: 1340000),
    ),
    m(
      false,
      '',
      hour - min * 2,
      kind: MsgKind.note,
      att: Attachment(
        name: 'note.mp4',
        mime: 'video/mp4',
        size: 1460000,
        width: 1,
        height: 1,
        duration: 12,
      ),
    ),
  ];

  final dima = [
    m(false, 'Ты видел новый альбом?', day * 3),
    m(true, 'Да, третий трек — лучший', day * 3 - min * 10, reaction: '👍'),
    m(false, 'Согласен на 100%', day * 3 - min * 9),
  ];

  final sonya = [
    m(false, 'Не спишь? 🌚', day * 4 + hour * 2),
    m(true, 'Конечно нет 😅', day * 4 + hour),
  ];

  final trip = [
    m(
      false,
      'создал(а) группу «Поход на выходных»',
      hour * 6,
      kind: MsgKind.event,
      from: 'alice',
      ev: 'create',
    ),
    m(false, 'Кто берёт палатку? ⛺', hour * 5, from: 'alice'),
    m(false, 'У меня есть двухместная', hour * 5 - min * 4, from: 'max'),
    m(true, 'Я возьму горелку и котелок 🔥', hour * 4),
    m(false, 'А я — фотоаппарат 📸', hour * 3, from: 'kate', reaction: '❤️'),
  ];

  return {
    'alice': alice,
    'max': max,
    'kate': kate,
    'dima': dima,
    'sonya': sonya,
    demoGroupId: trip,
  };
}

const replyPhrases = [
  'Ахах, точно 😄',
  'Согласен!',
  'Подожди, сейчас гляну',
  'Звучит как план 👌',
  'Ого, не знала',
  'Да ладно?! 😱',
  'Ну ты даёшь',
  'Окей, договорились',
  'Хм, надо подумать 🤔',
  'Скинь потом подробнее',
  'Лучшая новость за день!',
  'Кстати, Veil реально летает 🚀',
  'Я в деле',
  'Позже наберу',
  '😂😂😂',
  '❤️',
];

const reactionEmojis = ['❤️', '🔥', '😂', '😮', '😢', '👍'];

/// Крошечное превью «заката» для демо-фото (PNG 32×24).
const demoSunsetThumb =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAm0lEQVR42mP8X5HHQEvA8oeVdahbwEJjC/7S2oI/zLS2gGmoW/CXkdY+oLkFDORYoOb5DZl7azsX7iD6T7IFml4fMe27vo0fhw/+UyeIcJnD8ucflSz4h8uCv1SyAIc5LH+pZAEuc1j+/CHZgiMrNWzCb6CJ4E6mv8nxwYElukSqZHRUCaBtRvv/n4m2Fvz7R2ML/g99C/7S1gIApjA6k6X3A68AAAAASUVORK5CYII=';

/// Демо-истории друзей (текстовые — чтобы работали без сети).
Map<String, List<Story>> demoStories() {
  final now = DateTime.now();
  return {
    'alice': [
      Story(
        id: 'demo-a1',
        author: 'alice',
        kind: 't',
        time: now.subtract(const Duration(hours: 3)),
        text: 'Нашла кофейню с лучшим рафом в городе ☕️',
        bg: 1,
      ),
      Story(
        id: 'demo-a2',
        author: 'alice',
        kind: 't',
        time: now.subtract(const Duration(minutes: 40)),
        text: 'Кто со мной на выставку в субботу? 🎨',
        bg: 3,
      ),
    ],
    'max': [
      Story(
        id: 'demo-m1',
        author: 'max',
        kind: 't',
        time: now.subtract(const Duration(hours: 6)),
        text: 'Первый снег в горах 🏔️🏂',
        bg: 5,
      ),
    ],
    'kate': [
      Story(
        id: 'demo-k1',
        author: 'kate',
        kind: 't',
        time: now.subtract(const Duration(hours: 9)),
        text: 'Закат сегодня просто 🔥',
        bg: 2,
        seen: true,
      ),
    ],
  };
}
