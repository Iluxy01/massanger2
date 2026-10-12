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
  ];
}

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
  }) {
    return Message(
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
    m(false, 'В 21:00, после заката 🌅', min * 2),
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

  return {'alice': alice, 'max': max, 'kate': kate, 'dima': dima, 'sonya': sonya};
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
