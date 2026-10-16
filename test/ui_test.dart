import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/models/models.dart';
import 'package:veil/screens/chats_tab.dart';
import 'package:veil/screens/settings_tab.dart';
import 'package:veil/screens/wifi_hint.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/widgets/avatar.dart';
import 'package:veil/widgets/effects.dart';
import 'package:veil/widgets/video_note.dart';
import 'package:veil/widgets/visual.dart';

/// Проверки визуальных исправлений (демо-режим, без сети).
void main() {
  Future<AppState> launch(WidgetTester tester, {bool banner = true}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = banner;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  testWidgets('при перелёте аватарки у эмодзи нет «двух полосок»', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    // Середина перехода — аватарка «летит» в оверлее, где нет Material.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final flying = find.text('🦊');
    expect(flying, findsWidgets);
    for (final el in flying.evaluate()) {
      final text = el.widget as Text;
      final style = DefaultTextStyle.of(el).style.merge(text.style);
      expect(style.decoration, anyOf(isNull, TextDecoration.none), reason: 'подчёркивание');
    }
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('галочки: ✓ доставлено, ✓✓ прочитано', (tester) async {
    final state = AppState.demo();
    Future<void> show(MsgStatus s) => tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          home: Material(
            child: StatusTicks(key: ValueKey(s), status: s, color: Colors.white),
          ),
        ),
      ),
    );
    await show(MsgStatus.delivered);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
    await show(MsgStatus.read);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('секретное сообщение открывается и скрывается касанием', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    final secret = state.messagesOf('alice').firstWhere((m) => m.secret);
    expect(secret.revealed, isFalse);
    final eye = find.byIcon(Icons.visibility_rounded);
    await tester.dragUntilVisible(eye, find.byType(ListView), const Offset(0, 250));
    await settle(tester);
    expect(eye, findsOneWidget);

    await tester.tap(eye);
    await settle(tester);
    expect(secret.revealed, isTrue, reason: 'первое касание открывает');
    expect(find.byIcon(Icons.visibility_rounded), findsNothing);

    await tester.tap(find.text('cosmos_2024!'));
    await settle(tester);
    expect(secret.revealed, isFalse, reason: 'второе касание скрывает');
    await close(tester, state);
  });

  testWidgets('всплывающее окошко можно отключить', (tester) async {
    for (final on in [true, false]) {
      final state = await launch(tester, banner: on);
      // В демо Катя присылает сообщение через 6 секунд после запуска.
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('сейчас'), on ? findsOneWidget : findsNothing, reason: 'banner=$on');
      await close(tester, state);
    }
  });

  testWidgets('уровни оформления и анимаций: все работают и сохраняются', (tester) async {
    // Без всплывашки: она тоже из стекла и сбила бы подсчёт.
    final state = await launch(tester, banner: false);
    int blurs() => find.byType(BackdropFilter).evaluate().length;
    final normal = blurs();

    for (final look in [0, 2, 1]) {
      for (final motion in [0, 1, 3, 2]) {
        state.setLook(look);
        state.setMotion(motion);
        await settle(tester);
        final v = Visual.of(tester.element(find.byType(Scaffold).first));
        expect((v.look, v.motion), (look, motion));
        // Заходим в чат и выходим — без ошибок на любом уровне.
        await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
        await settle(tester);
        expect(find.text('Что берём на крышу?'), findsOneWidget);
        navigatorKey.currentState!.pop();
        await settle(tester);
        if (look == 0) expect(blurs(), 0, reason: 'минимум — без размытия');
        if (look == 2) expect(blurs(), greaterThan(normal), reason: 'максимум — стекло везде');
      }
    }
    expect(blurs(), normal, reason: 'по умолчанию всё как раньше');

    // Сохраняются вместе с остальными настройками.
    state.setLook(0);
    state.setMotion(3);
    final copy = AppState.demo()..applySettings(state.settingsForTest);
    expect((copy.look, copy.motion), (0, 3));
    copy.dispose();
    await close(tester, state);
  });

  testWidgets('опрос: голос, проценты, отмена голоса', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    final poll = state.messagesOf('alice').firstWhere((m) => m.kind == MsgKind.poll);
    expect(find.text('Что берём на крышу?'), findsOneWidget);
    expect(find.text('Проголосовали: 1'), findsOneWidget);
    expect(find.text('100%'), findsNothing, reason: 'до своего голоса результаты скрыты');

    await tester.tap(find.text('Какао'));
    await settle(tester);
    expect(poll.poll!.of('me'), [1]);
    expect(find.text('Проголосовали: 2'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.text('Чай в термосе'));
    await settle(tester);
    expect(poll.poll!.of('me'), [0], reason: 'один вариант — голос переносится');
    expect(find.text('50%'), findsNWidgets(2));

    await tester.tap(find.text('Чай в термосе'));
    await settle(tester);
    expect(poll.poll!.of('me'), isEmpty, reason: 'повторное касание — отозвать');
    await close(tester, state);
  });

  testWidgets('геопозиция, фото и документ в пузырях', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    expect(find.text('Геопозиция · ±15 м'), findsOneWidget);
    Navigator.of(tester.element(find.text('Геопозиция · ±15 м'))).pop();
    await settle(tester);

    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-kate').first);
    await settle(tester);
    // Фото ещё не скачано: размытое превью, размер и кнопка «скачать».
    expect(find.textContaining('Тот самый закат'), findsOneWidget);
    expect(find.text('822 КБ'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNWidgets(3));
    expect(find.text('Маршрут_поездки.pdf'), findsOneWidget);
    expect(find.text('1,3 МБ · скачать'), findsOneWidget);
    // В списке чатов — понятная подпись.
    expect(
      state.messagesOf('kate').firstWhere((m) => m.kind == MsgKind.file).preview,
      '📎 Маршрут_поездки.pdf',
    );
    await close(tester, state);
  });

  testWidgets('видеосообщение: квадратик в чате, кнопка микрофон ↔ камера', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-kate').first);
    await settle(tester);
    // Ещё не скачано: квадратик с длительностью, размером и кнопкой «скачать».
    expect(find.byType(NoteBubble), findsOneWidget);
    expect(find.text('0:12 · 1,4 МБ'), findsOneWidget);
    final box = tester.getSize(find.byType(NoteBubble));
    expect(box.width, box.height, reason: 'квадрат');
    expect(
      state.messagesOf('kate').firstWhere((m) => m.kind == MsgKind.note).preview,
      '📹 Видеосообщение · 0:12',
    );
    // Короткое нажатие на микрофон — режим видеосообщения, и обратно.
    final mics = find.byIcon(Icons.mic_rounded).evaluate().length;
    await tester.tap(find.byIcon(Icons.mic_rounded).last);
    await settle(tester);
    expect(find.byIcon(Icons.mic_rounded), findsNWidgets(mics - 1));
    expect(find.byIcon(Icons.videocam_rounded), findsWidgets);
    expect(find.textContaining('Видеосообщение: удерживай'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.videocam_rounded).last);
    await settle(tester);
    expect(find.textContaining('Голосовое: удерживай'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4)); // подсказка исчезла
    await settle(tester);
    expect(find.byIcon(Icons.mic_rounded), findsNWidgets(mics));
    await close(tester, state);
  });

  testWidgets('настройка: с какой камеры начинать видеосообщение', (tester) async {
    final state = await launch(tester, banner: false);
    expect(state.noteCamera, 0, reason: 'по умолчанию — фронтальная');
    // Вкладка «Профиль» — аватарка в нижней панели.
    await tester.tap(find.byWidgetPredicate((w) => w is Avatar && w.size == 26).last);
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Тонкие настройки'),
      300,
      scrollable: find
          .descendant(of: find.byType(SettingsTab), matching: find.byType(Scrollable))
          .first,
    );
    await settle(tester);
    await tester.tap(find.text('Тонкие настройки'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Камера в начале записи'), 300);
    await settle(tester);
    await tester.tap(find.text('Основная'));
    await settle(tester);
    expect(state.noteCamera, 1);
    expect(find.textContaining('Сначала снимает то, что перед тобой'), findsOneWidget);
    final copy = AppState.demo()..applySettings(state.settingsForTest);
    expect(copy.noteCamera, 1, reason: 'сохраняется');
    copy.dispose();
    await close(tester, state);
  });

  testWidgets('группа: события, имена авторов, участники', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.scrollUntilVisible(
      find.text('Поход на выходных'),
      200,
      scrollable: find
          .descendant(of: find.byType(ChatsTab), matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(find.text('Поход на выходных'));
    await settle(tester);
    expect(find.text('4 участника'), findsOneWidget);
    expect(find.text('Алиса создал(а) группу «Поход на выходных»'), findsOneWidget);
    // Имя автора над его сообщениями (у своих — нет).
    expect(find.text('Макс'), findsOneWidget);
    expect(find.text('Катя'), findsOneWidget);
    // Сообщение в группу.
    await tester.enterText(find.byType(TextField).last, 'Выезжаем в 8');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('Выезжаем в 8'), findsOneWidget);
    // Экран группы: участники и администратор.
    await tester.tap(find.text('4 участника'));
    await settle(tester);
    expect(find.text('Участники'), findsOneWidget);
    expect(find.text('администратор'), findsOneWidget);
    expect(find.text('Ты'), findsOneWidget);
    expect(find.text('Выйти из группы'), findsOneWidget);
    expect(find.byIcon(Icons.remove_circle_outline_rounded), findsNothing, reason: 'не админ');
    await close(tester, state);
  });

  testWidgets('новая группа: название, участники, создание', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(
      find.descendant(of: find.byType(ChatsTab), matching: find.byIcon(Icons.edit_rounded)),
    );
    await settle(tester);
    await tester.tap(find.text('Новая группа'));
    await settle(tester);
    expect(find.text('Создать группу'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Кино');
    await tester.tap(find.text('Соня'));
    await tester.tap(find.text('Дима'));
    await tester.pump();
    await tester.tap(find.text('Создать группу'));
    await settle(tester);
    final g = state.contacts.lastWhere((c) => c.isGroup);
    expect(g.name, 'Кино');
    expect(g.group!.members.map((m) => m.pub), ['me', 'sonya', 'dima']);
    expect(g.group!.admin, 'me');
    expect(find.text('3 участника'), findsOneWidget, reason: 'открылся чат группы');
    expect(find.text('Ты создал(а) группу «Кино»'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('меню сообщения: изменить, закрепить, поиск, оформление', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    const mineText = 'Удобно, что всё хранится только у нас на телефонах 😌';
    await tester.dragUntilVisible(find.text(mineText), find.byType(ListView), const Offset(0, 250));
    await settle(tester);
    await tester.longPress(find.text(mineText));
    await settle(tester);
    for (final a in [
      'Ответить',
      'Переслать',
      'Изменить',
      'Закрепить',
      'В избранное',
      'Удалить у всех',
    ]) {
      expect(find.text(a), findsOneWidget, reason: a);
    }
    await tester.tap(find.text('Изменить'));
    await settle(tester);
    expect(find.text('Редактирование'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Всё хранится *только* у нас 😌');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    final edited = state.messagesOf('alice').firstWhere((m) => m.text.contains('только*'));
    expect(edited.edited, isTrue);
    expect(find.textContaining('изм.'), findsWidgets);
    // Оформление: в пузыре без звёздочек.
    expect(find.text('Всё хранится только у нас 😌'), findsOneWidget);

    // Закрепить — полоска вверху.
    await tester.longPress(find.text('Всё хранится только у нас 😌'));
    await settle(tester);
    await tester.tap(find.text('Закрепить'));
    await settle(tester);
    expect(find.text('Закреплено'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));

    // Поиск в чате.
    await tester.tap(find.byTooltip('Поиск в чате'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Поиск в чате'), 'термос');
    await settle(tester);
    expect(find.text('1 из 1'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('тонкие настройки: сохраняются и работают', (tester) async {
    final state = await launch(tester, banner: false);
    expect(find.textContaining('Го в субботу'), findsNothing);
    expect(find.text('🔥🔥'), findsWidgets, reason: 'последнее у Алисы — видно в списке');
    state.setFlag(() {
      state.hidePreviews = true;
      state.msgFont = 2;
      state.enterSends = true;
      state.quickReaction = '';
      state.swipeReply = false;
      state.autoVideo = false;
      state.confirmDelete = true;
      state.notesAutoplay = false;
    });
    await settle(tester);
    expect(find.text('🔥🔥'), findsNothing, reason: 'текст в списке скрыт');
    expect(find.text('Новое сообщение'), findsWidgets);
    final copy = AppState.demo()..applySettings(state.settingsForTest);
    expect(
      (
        copy.hidePreviews,
        copy.msgFont,
        copy.msgFontSize,
        copy.enterSends,
        copy.quickReaction,
        copy.swipeReply,
        copy.autoVideo,
        copy.confirmDelete,
        copy.notesAutoplay,
      ),
      (true, 2, 18.5, true, '', false, false, true, false),
    );
    final video = Message(
      id: 'v',
      mine: false,
      text: '',
      time: DateTime.now(),
      kind: MsgKind.video,
    );
    expect(copy.autoDownload(video), isFalse);
    expect(
      state.autoDownload(
        Message(id: 'p', mine: false, text: '', time: DateTime.now(), kind: MsgKind.photo),
      ),
      isTrue,
    );
    copy.dispose();
    await close(tester, state);
  });

  testWidgets('режим «Ультра»: переключатель, минимум оформления, значок', (tester) async {
    final state = await launch(tester, banner: false);
    state.setDark(false);
    await settle(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Avatar && w.size == 26).last);
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Режим «Ультра»'),
      300,
      scrollable: find
          .descendant(of: find.byType(SettingsTab), matching: find.byType(Scrollable))
          .first,
    );
    await settle(tester);
    expect(find.text('Максимальная экономия батареи'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text('Режим «Ультра»'), matching: find.byType(Row)).first,
        matching: find.byType(VeilSwitch),
      ),
    );
    await settle(tester);
    expect(state.ultra, isTrue);
    expect(find.text('Включён — максимальная экономия'), findsOneWidget);
    final v = Visual.of(tester.element(find.byType(Scaffold).first));
    expect((v.look, v.motion), (0, 0));
    expect(state.colors.dark, isTrue, reason: 'в «Ультра» всегда тёмная');
    expect(state.look, 1, reason: 'свой выбор не потерян');
    // На главной — значок молнии.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Icon && w.icon == Icons.chat_bubble_rounded && w.size == null,
      ),
    );
    await settle(tester);
    expect(
      find.descendant(of: find.byType(ChatsTab), matching: find.byIcon(Icons.bolt_rounded)),
      findsOneWidget,
    );
    await state.setUltra(false);
    await settle(tester);
    expect(state.colors.dark, isFalse);
    await close(tester, state);
  });

  testWidgets('одноразовое: переключатель в меню, пузырь без превью', (tester) async {
    final state = await launch(tester, banner: false);
    state
        .messagesOf('dima')
        .add(
          Message(
            id: 'once1',
            mine: false,
            text: '',
            time: DateTime.now(),
            status: MsgStatus.delivered,
            kind: MsgKind.photo,
            once: true,
            att: Attachment(name: 'x.jpg', mime: 'image/jpeg', size: 1000, key: 'k', chunks: 1),
          ),
        );
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-dima').first);
    await settle(tester);
    expect(find.text('Одноразовое фото'), findsOneWidget);
    expect(find.text('Нажми, чтобы загрузить'), findsOneWidget);
    // Меню на одноразовом: ни переслать, ни поделиться, ни в избранное.
    await tester.longPress(find.text('Одноразовое фото'));
    await settle(tester);
    expect(find.text('Переслать'), findsNothing);
    expect(find.text('В избранное'), findsNothing);
    await tester.tapAt(const Offset(20, 120));
    await settle(tester);
    // «🔥 Одноразовый просмотр» в меню вложений — и напоминание над полем ввода.
    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    expect(find.text('Одноразовый просмотр'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text('Одноразовый просмотр'), matching: find.byType(Row)).first,
        matching: find.byType(VeilSwitch),
      ),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    expect(find.textContaining('— одноразовое'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('капсула времени закрыта; общий список отмечается касанием', (tester) async {
    final state = await launch(tester, banner: false);
    state.messagesOf('dima').addAll([
      Message(
        id: 'cap1',
        mine: false,
        text: 'секрет до лета',
        time: DateTime.now(),
        openAt: DateTime.now().add(const Duration(days: 3)),
      ),
      Message(
        id: 'todo1',
        mine: false,
        text: '',
        time: DateTime.now(),
        kind: MsgKind.todo,
        todo: Todo(
          title: 'Купить',
          items: [
            TodoItem(id: 'x1', text: 'Хлеб'),
            TodoItem(id: 'x2', text: 'Сыр'),
          ],
        ),
      ),
    ]);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-dima').first);
    await settle(tester);
    expect(find.text('Капсула времени'), findsOneWidget);
    expect(find.text('секрет до лета'), findsNothing, reason: 'текст закрыт');
    expect(find.textContaining('через 2 дн.'), findsOneWidget);
    expect(find.text('Список · готово 0 из 2'), findsOneWidget);
    await tester.tap(find.text('Сыр'));
    await settle(tester);
    expect(find.text('Список · готово 1 из 2'), findsOneWidget);
    // Меню вложений: есть «Список».
    await tester.tap(find.byIcon(Icons.add_rounded).last);
    await settle(tester);
    expect(find.text('Список'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('подсказка про Wi-Fi: причина по кнопке «Подробнее»', (tester) async {
    final state = await launch(tester, banner: false);
    final ctx = tester.element(find.byType(Scaffold).first);
    bool? answer;
    showWifiHintSheet(ctx).then((v) => answer = v);
    await settle(tester);
    expect(find.text('Отправь через мобильный интернет'), findsOneWidget);
    expect(find.textContaining('Почему так'), findsNothing);
    await tester.tap(find.text('Подробнее'));
    await settle(tester);
    expect(find.textContaining('Почему так'), findsOneWidget);
    await tester.ensureVisible(find.text('Понятно, отправить'));
    await settle(tester);
    await tester.tap(find.text('Понятно, отправить'));
    await settle(tester);
    expect(answer, isTrue);
    await close(tester, state);
  });

  testWidgets('меню вложений: опрос и геопозиция отправляются', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-dima').first);
    await settle(tester);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    for (final label in ['Фото', 'Камера', 'Видео', 'Файл', 'Место', 'Опрос']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('Опрос'));
    await settle(tester);
    expect(find.text('Новый опрос'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Во сколько созвон?');
    await tester.enterText(fields.at(1), '19:00');
    await tester.enterText(fields.at(2), '20:00');
    await tester.pump();
    await tester.tap(find.text('Отправить опрос'));
    await settle(tester);
    // Демо-друг иногда отвечает сам — берём своё последнее сообщение.
    final sent = state.messagesOf('dima').lastWhere((m) => m.mine);
    expect(sent.kind, MsgKind.poll);
    expect(sent.poll!.question, 'Во сколько созвон?');
    expect(sent.poll!.options, ['19:00', '20:00']);
    expect(find.text('Во сколько созвон?'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    await tester.tap(find.text('Место'));
    await settle(tester);
    await settle(tester); // поиск места в демо + появление листа
    expect(find.text('Отправить геопозицию'), findsOneWidget);
    await tester.tap(find.text('Отправить геопозицию'));
    await settle(tester);
    final geo = state.messagesOf('dima').lastWhere((m) => m.mine);
    expect(geo.kind, MsgKind.geo);
    expect(geo.geo!.lat, closeTo(55.75, 0.01));
    await close(tester, state);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
