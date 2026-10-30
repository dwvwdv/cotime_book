// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'CoTime Book';

  @override
  String get mastheadTagline => 'Read together, anywhere';

  @override
  String get pressBackAgainToExit => 'Press back again to exit';

  @override
  String get activeRoom => 'Active room';

  @override
  String get continueAction => 'Continue';

  @override
  String get leaving => 'Leaving...';

  @override
  String get leaveRoom => 'Leave Room';

  @override
  String get nickname => 'Nickname';

  @override
  String get nicknameHint => 'What should others call you?';

  @override
  String get back => 'Back';

  @override
  String get joining => 'Joining...';

  @override
  String get joinRoom => 'Join Room';

  @override
  String get creating => 'Creating...';

  @override
  String get createRoom => 'Create Room';

  @override
  String get supabaseNotConfigured =>
      'Supabase not configured.\nRun with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...';

  @override
  String get connected => 'Connected';

  @override
  String get connecting => 'Connecting...';

  @override
  String get tapToConnect => 'Tap to connect';

  @override
  String get enterNickname => 'Please enter a nickname';

  @override
  String get leaveBeforeCreating =>
      'Leave the active room before creating another one.';

  @override
  String get enterValidRoomCode => 'Please enter a valid 6-character room code';

  @override
  String get leaveBeforeJoining =>
      'Leave the active room before joining another one.';

  @override
  String cleanupRoomMembership(String error) {
    return 'room membership: $error';
  }

  @override
  String cleanupRealtimePresence(String error) {
    return 'realtime presence: $error';
  }

  @override
  String roomCleanupNeedsAttention(String errors) {
    return 'Room cleanup needs attention: $errors';
  }

  @override
  String get txtToEpub => 'TXT to EPUB';

  @override
  String get moreApps => 'More Apps';

  @override
  String get news => 'News';

  @override
  String get txtConvertIntro =>
      'Make an EPUB from TXT files and read it here to check the text and chapters. Save it once it looks right, then share the saved EPUB in a room.';

  @override
  String get pickTxtFiles => 'Pick TXT Files';

  @override
  String get converted => 'Converted';

  @override
  String get read => 'Read';

  @override
  String get saving => 'Saving...';

  @override
  String get saveAgain => 'Save Again';

  @override
  String get saveEpub => 'Save EPUB';

  @override
  String get savedShareInRoom =>
      'Saved. In a room, tap Share Book and pick this file.';

  @override
  String get convertOtherFiles => 'Convert Other Files';

  @override
  String get opening => 'Opening...';

  @override
  String get reading => 'Reading...';

  @override
  String get converting => 'Converting...';

  @override
  String get pickOnlyTxt =>
      'Pick only TXT files. An EPUB needs no converting: share it in a room as it is.';

  @override
  String txtSourcesTooLarge(int count, String size, String limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'These files are',
      one: 'This file is',
    );
    return '$_temp0 $size. A book can be made of at most $limit of text.';
  }

  @override
  String convertedBookTooLarge(String size, String limit) {
    return 'The book came out at $size. Books can be at most $limit.';
  }

  @override
  String couldNotSaveEpub(String error) {
    return 'Could not save the EPUB: $error';
  }

  @override
  String get roomNotOnDevice => 'This room is not available on this device.';

  @override
  String roomLinkMismatch(String link, String code) {
    return 'Room link $link does not match your active room $code.';
  }

  @override
  String get unknownBook => 'Unknown';

  @override
  String get roomClosed => 'This room has been closed.';

  @override
  String get roomInitCancelled => 'Room initialization was cancelled.';

  @override
  String get authTimedOut =>
      'Authentication timed out. Please return home and retry.';

  @override
  String get openingRoom => 'Opening the room...';

  @override
  String get roomNoLongerAvailable => 'This room is no longer available.';

  @override
  String get roomLobby => 'Room Lobby';

  @override
  String get leaveRoomTooltip => 'Leave room';

  @override
  String get roomCodeOverline => 'ROOM CODE';

  @override
  String get members => 'Members';

  @override
  String onlineCount(int count) {
    return '$count online';
  }

  @override
  String get loading => 'Loading...';

  @override
  String get shareBook => 'Share Book';

  @override
  String get library => 'Library';

  @override
  String get startReading => 'Start Reading';

  @override
  String get joinReading => 'Join Reading';

  @override
  String get reconnectingToRoom => 'Reconnecting to the room...';

  @override
  String get onlyHostCanStart => 'Only the room host can start reading.';

  @override
  String unableToStartReading(String error) {
    return 'Unable to start reading: $error';
  }

  @override
  String get readingStartedWaitForBook =>
      'Reading has started. You can join as soon as the book arrives.';

  @override
  String get bookNotOnDevice => 'The book is not on this device yet.';

  @override
  String get roomUnavailable => 'Room unavailable';

  @override
  String get returnHome => 'Return Home';

  @override
  String get readyToRead => 'Ready to read';

  @override
  String get receivingBook => 'Receiving book...';

  @override
  String appOutOfDate(String names, int count, String appName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'are',
      one: 'is',
    );
    return 'Your app is out of date: $names $_temp0 on a newer version. Update $appName to read together.';
  }

  @override
  String othersNeedUpdate(String names, int count, String appName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'need',
      one: 'needs',
    );
    return '$names $_temp0 to update $appName to read together.';
  }

  @override
  String get shareBookToStart => 'Share a book to start reading.';

  @override
  String get waitingForBookShare => 'Waiting for someone to share a book.';

  @override
  String get bookOnItsWay => 'The book is on its way to this device.';

  @override
  String get connectingToRoom => 'Connecting to the room...';

  @override
  String get hostStartsSession => 'The host starts the reading session.';

  @override
  String stillReceivingBook(String names, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'are',
      one: 'is',
    );
    return '$names $_temp0 still receiving the book and can join when it arrives.';
  }

  @override
  String get listSeparator => ', ';

  @override
  String get themePaper => 'Paper';

  @override
  String get themeNight => 'Night';

  @override
  String get themeSepia => 'Sepia';

  @override
  String get couldNotChangeTextSize =>
      'Couldn\'t change the room\'s text size. Try again in a moment.';

  @override
  String get reader => 'Reader';

  @override
  String get openingBook => 'Opening the book...';

  @override
  String get noBookLoaded => 'No book loaded';

  @override
  String get backToLobby => 'Back to Lobby';

  @override
  String get leaveReading => 'Leave reading';

  @override
  String get readingSettingsTooltip => 'Reading settings';

  @override
  String get readingSettings => 'Reading Settings';

  @override
  String get settingsPage => 'Page';

  @override
  String get settingsTextSize => 'Text size';

  @override
  String get textSizeTakesSeconds =>
      'A new text size takes a few seconds to show: the book is laid out again on every reader\'s screen. Wait for the page to change before tapping again or turning.';

  @override
  String get onlyISetTextSize => 'Only I set the text size';

  @override
  String get onlyISetTextSizeHint =>
      'Turn off to let everyone pick a size. The room then reads at the largest size anyone picked.';

  @override
  String get settingsTurningPages => 'Turning pages';

  @override
  String get volumeKeysTurnPages => 'Volume keys turn pages';

  @override
  String get volumeKeysTurnPagesHint =>
      'For e-readers whose page buttons act as volume keys.';

  @override
  String get tapZonesHint =>
      'Tap the left third of the page to go back, anywhere else to go forward. Page Up/Down and arrow keys work too.';

  @override
  String get settingsTroubleshooting => 'Troubleshooting';

  @override
  String get pageLayoutReport => 'Page Layout Report';

  @override
  String themeOptionLabel(String theme) {
    return '$theme theme';
  }

  @override
  String get youSetTextSize =>
      'You set the text size for everyone in this room.';

  @override
  String get hostSetsTextSize => 'The host sets the text size in this room.';

  @override
  String get everyoneSeesSamePage =>
      'Everyone sees the same page: it fits the smallest screen in the room, at the largest text size anyone picked.';

  @override
  String anotherReaderPickedSize(int size, String shared) {
    return 'Another reader picked $size, so the room reads at $size. $shared';
  }

  @override
  String get roomMembers => 'Room members';

  @override
  String waitingForReconnect(String names) {
    return 'Waiting for $names to reconnect...';
  }

  @override
  String get adBreakEllipsis => 'Ad break...';

  @override
  String adBreakWaitingFor(String names) {
    return 'Ad break: waiting for $names...';
  }

  @override
  String readersReady(int count) {
    return '$count readers ready';
  }

  @override
  String get synced => 'Synced';

  @override
  String waitingForNames(String names) {
    return 'Waiting for $names...';
  }

  @override
  String get wait => 'Wait';

  @override
  String get go => 'Go';

  @override
  String get turn => 'Turn';

  @override
  String waitingForOthersToConfirm(int confirmed, int required) {
    return 'Waiting for others to confirm... $confirmed/$required';
  }

  @override
  String get jumpingToPage => 'Jumping to the page...';

  @override
  String get turningPage => 'Turning page...';

  @override
  String get unknownMember => 'Unknown';

  @override
  String wantsNextPage(String who) {
    return '$who wants to go to next page';
  }

  @override
  String wantsPreviousPage(String who) {
    return '$who wants to go to previous page';
  }

  @override
  String wantsJumpElsewhere(String who) {
    return '$who wants to jump to another page';
  }

  @override
  String wantsJumpToPage(String who, String page) {
    return '$who wants to jump to page $page';
  }

  @override
  String wantsJumpToPageWithProgress(String who, String page, String progress) {
    return '$who wants to jump to page $page ($progress)';
  }

  @override
  String askToLeaveTooltip(String nickname) {
    return 'Ask $nickname to leave';
  }

  @override
  String askToLeaveTitle(String nickname) {
    return 'Ask $nickname to leave?';
  }

  @override
  String askToLeaveMessage(String nickname) {
    return '$nickname will be taken out of the room, and nobody waits for them to turn the page. They can join again with the room code.\n\nIf others are here too, more than half of you have to agree.';
  }

  @override
  String get askToLeave => 'Ask to leave';

  @override
  String removeMemberTitle(String nickname) {
    return 'Remove $nickname?';
  }

  @override
  String get voteIsOver => 'This vote is over.';

  @override
  String get close => 'Close';

  @override
  String removalVoteMessage(String voter, String target) {
    return '$voter asked $target to leave the room, so nobody waits for them to turn the page. $target can join again with the room code.';
  }

  @override
  String moreVotesNeeded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more votes needed.',
      one: '1 more vote needed.',
    );
    return '$_temp0';
  }

  @override
  String get agree => 'Agree';

  @override
  String get notNow => 'Not now';

  @override
  String couldNotAskToLeave(String nickname) {
    return 'Could not ask $nickname to leave. Try again.';
  }

  @override
  String memberRemoved(String nickname) {
    return '$nickname was removed from the room.';
  }

  @override
  String memberGone(String nickname) {
    return '$nickname is no longer in the room.';
  }

  @override
  String voteIn(int count, String nickname) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Your vote is in. $count more votes needed to remove $nickname.',
      one: 'Your vote is in. 1 more vote needed to remove $nickname.',
    );
    return '$_temp0';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get noMembersYet => 'No members yet';

  @override
  String get needsAppUpdate => 'Needs app update';

  @override
  String get newerAppUpdateYours => 'Newer app — update yours';

  @override
  String get youSuffix => '  (You)';

  @override
  String get online => 'Online';

  @override
  String get awayNotConnected => 'Away — not connected';

  @override
  String get hasBook => 'Has book';

  @override
  String get noBook => 'No book';

  @override
  String membersOnline(int count) {
    return '$count Members Online';
  }

  @override
  String get statusReading => 'Reading';

  @override
  String get statusLeftReader => 'Left the reader';

  @override
  String get statusNotConnected => 'Not connected';

  @override
  String get adBreakPageOpensWhenBack =>
      'The page opens when every reader is back.';

  @override
  String adBreakWaitingForAd(String names) {
    return 'Waiting for $names to finish an ad...';
  }

  @override
  String get adBreak => 'Ad break';

  @override
  String get ads => 'Ads';

  @override
  String get adPrivacyChoices => 'Ad Privacy Choices';

  @override
  String get adPrivacyChoicesHint =>
      'Change what you agreed to for the ads in this app.';

  @override
  String get announcementsLoadFailed =>
      'The announcements could not be loaded.';

  @override
  String get tryAgain => 'Try Again';

  @override
  String get noAnnouncements => 'No announcements yet.';

  @override
  String get contents => 'Contents';

  @override
  String contentsEntries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count entries',
      one: '1 entry',
    );
    return '$_temp0';
  }

  @override
  String get noContents => 'This book has no contents.';

  @override
  String get untitled => '(untitled)';

  @override
  String get stillWorkingOutLength =>
      'Still working out the length of the book. Try again in a moment.';

  @override
  String get jumpPageLabel => 'Page';

  @override
  String get jumpHere => 'Here';

  @override
  String get previousPage => 'Previous page';

  @override
  String get nextPage => 'Next page';

  @override
  String get positionInBook => 'Position in the book';

  @override
  String get reportRateLimited =>
      'Too many reports in the last hour. Try again later.';

  @override
  String get reportSendFailed => 'Couldn\'t send the report. Try again.';

  @override
  String get pageLayoutReportTitle => 'Page layout report';

  @override
  String get pageLayoutReportIntro =>
      'If pages are cut off or a turn skips ahead, send this right after it happens. It holds how this screen laid out the page and where you are in the book, never the book\'s text.';

  @override
  String get reportNoteHint => 'What went wrong? (optional)';

  @override
  String get reportSentToHistory =>
      'Sent. You can follow it in Report History on the home screen.';

  @override
  String get sending => 'Sending...';

  @override
  String get sendReport => 'Send Report';

  @override
  String get reportHistory => 'Report History';

  @override
  String reportHistoryUpdates(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count of your reports have answers',
      one: 'One of your reports has an answer',
    );
    return '$_temp0';
  }

  @override
  String get reportHistoryEmpty => 'You haven\'t sent any reports.';

  @override
  String get reportHistoryLoadFailed =>
      'Couldn\'t load your reports. Check the connection and try again.';

  @override
  String get reportStatusOpen => 'Pending';

  @override
  String get reportStatusResolved => 'Resolved';

  @override
  String get reportStatusUpdateNeeded => 'Update needed';

  @override
  String get reportStatusDeclined => 'Not fixed';

  @override
  String reportFixedIn(String version) {
    return 'Fixed in $version';
  }

  @override
  String reportUpdateForFix(String version) {
    return 'Fixed in $version. Update the app to get the fix.';
  }

  @override
  String reportSentAt(String time) {
    return 'Sent $time';
  }

  @override
  String reportHandledAt(String time) {
    return 'Handled $time';
  }

  @override
  String get reportUnknownBook => 'Book not recorded';

  @override
  String reportYourNote(String note) {
    return 'Your note: $note';
  }

  @override
  String get languageChineseTraditional => 'Chinese (Traditional)';

  @override
  String get languageChineseSimplified => 'Chinese (Simplified)';

  @override
  String get languageChinese => 'Chinese';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageJapanese => 'Japanese';

  @override
  String get languageKorean => 'Korean';

  @override
  String get languageFrench => 'French';

  @override
  String get languageGerman => 'German';

  @override
  String get languageSpanish => 'Spanish';

  @override
  String get languageItalian => 'Italian';

  @override
  String get languagePortuguese => 'Portuguese';

  @override
  String get languageRussian => 'Russian';

  @override
  String get languageLatin => 'Latin';

  @override
  String get languageGreek => 'Greek';

  @override
  String get languageDutch => 'Dutch';

  @override
  String get languageVietnamese => 'Vietnamese';

  @override
  String get languageThai => 'Thai';

  @override
  String get libraryOpenFailed => 'The library could not be opened.';

  @override
  String get libraryNoteLoadFailed => 'The note could not be loaded.';

  @override
  String get publicLibrary => 'Public Library';

  @override
  String get aboutTheseBooks => 'About these books';

  @override
  String get searchByTitleOrAuthor => 'Search by title or author';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get books => 'Books';

  @override
  String bookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count books',
      one: '1 book',
    );
    return '$_temp0';
  }

  @override
  String shownOfBooks(int shown, String total) {
    return '$shown of $total';
  }

  @override
  String get loadingLibrary => 'Loading the library...';

  @override
  String get libraryEmpty => 'The library is empty for now.';

  @override
  String get noBooksMatch => 'No books match.';

  @override
  String get clearSearchAndFilters => 'Clear Search and Filters';

  @override
  String get filters => 'Filters';

  @override
  String get tags => 'Tags';

  @override
  String get booksWithAnyTag => 'Books with any of them';

  @override
  String get language => 'Language';

  @override
  String get all => 'All';

  @override
  String get noNoteYet => 'No note has been written yet.';

  @override
  String get aboutTheseBooksOverline => 'ABOUT THESE BOOKS';

  @override
  String get getItOnGooglePlay => 'Get it on Google Play';

  @override
  String get googlePlayCouldNotOpen =>
      'Google Play could not be opened on this device. The link:';

  @override
  String get goToPage => 'Go to page';

  @override
  String pageCounterLabel(int page, int pages) {
    return 'Page $page of $pages in this chapter';
  }

  @override
  String pageCounterProgress(String progress) {
    return ', $progress of the book';
  }

  @override
  String get pageCounterGoTo => '. Go to page';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get recentRooms => 'Recent rooms';

  @override
  String get noBookYet => 'No book yet';

  @override
  String recentRoomSubtitle(String book, String visit) {
    return '$book · $visit';
  }

  @override
  String removeFromRecentRooms(String code) {
    return 'Remove $code from recent rooms';
  }

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String daysAgo(int days) {
    return '$days days ago';
  }

  @override
  String roomCodeSemantics(String code) {
    return 'Room code $code. Tap to copy.';
  }

  @override
  String get roomCodeCopied => 'Room code copied';

  @override
  String get tapToCopy => 'Tap to copy';

  @override
  String get roomCode => 'Room code';

  @override
  String get waitingForTheBook => 'Waiting for the book';

  @override
  String get sendingBook => 'Sending book...';

  @override
  String get bookSent => 'Book sent';

  @override
  String get bookReceived => 'Book received';

  @override
  String get missedPartsWillAsk =>
      'Anyone who missed part of it will ask for the rest.';

  @override
  String get readyToReadSentence => 'Ready to read.';

  @override
  String get makeBookFromTxt => 'Make a book from TXT';

  @override
  String txtFilesBecomeOneEpub(int count) {
    return 'These $count files become one EPUB, in this order. You can read it before saving it.';
  }

  @override
  String get txtFileBecomesEpub =>
      'This file becomes an EPUB. You can read it before saving it.';

  @override
  String get title => 'Title';

  @override
  String get authorOptional => 'Author (optional)';

  @override
  String get files => 'Files';

  @override
  String get file => 'File';

  @override
  String get splitByLength => 'Split by length';

  @override
  String get noChaptersFound => 'No chapters found';

  @override
  String chapterCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chapters',
      one: '1 chapter',
    );
    return '$_temp0';
  }

  @override
  String get splitIntoChapters => 'Split into chapters';

  @override
  String get splitIntoChaptersHint =>
      'Turn off if lines that are not chapter titles were taken for them. The book is then split by length.';

  @override
  String get makeEpub => 'Make EPUB';

  @override
  String get noTextInEncoding => 'No text in this encoding; it will be skipped';

  @override
  String characterCount(String count) {
    return '$count characters';
  }

  @override
  String splitByLengthWithCharacters(String characters) {
    return 'Split by length · $characters';
  }

  @override
  String noChapterHeadingsWithCharacters(String characters) {
    return 'No chapter headings, split by length · $characters';
  }

  @override
  String chaptersWithCharacters(String chapters, String characters) {
    return '$chapters · $characters';
  }

  @override
  String get textEncoding => 'Text encoding';

  @override
  String encodingLabel(String encoding) {
    return 'Encoding: $encoding';
  }

  @override
  String get moveUp => 'Move up';

  @override
  String get moveDown => 'Move down';

  @override
  String get previous => 'Previous';

  @override
  String get next => 'Next';

  @override
  String onlyYouSeeThis(int percent) {
    return 'Only you see this · $percent%';
  }

  @override
  String pageNotFound(String uri) {
    return 'Page not found: $uri';
  }

  @override
  String get invalidRoomLink => 'Invalid room link';

  @override
  String get joinFromHomeFirst =>
      'Join this room from Home before opening this page.';

  @override
  String get notEpub =>
      'Only EPUB books can be shared. Make a TXT file into one with \"TXT to EPUB\" on the home screen first.';

  @override
  String libraryDownloadFailed(String title, String error) {
    return 'Could not get \"$title\" from the library: $error';
  }

  @override
  String get bookFileEmpty => 'The book file is empty';

  @override
  String bookTooLarge(String size, String limit) {
    return 'This book is $size. Books can be at most $limit.';
  }

  @override
  String get membershipInactive =>
      'This room membership is inactive or has expired.';

  @override
  String get roomStateChanged =>
      'Room state changed before the update could finish';

  @override
  String roomNoLongerAvailableCode(String code) {
    return 'Room $code is no longer available.';
  }

  @override
  String get roomUpdatedByAnotherClient =>
      'Room state was updated by another client';

  @override
  String get notAuthenticated => 'Not authenticated';

  @override
  String get removedFromRoom =>
      'You are no longer in this room. It may have closed, or you left it on another device.';

  @override
  String get removedByVote =>
      'The other readers removed you from this room. You can join again with the room code.';

  @override
  String get bookStillLoading => 'The book is still loading';

  @override
  String get reconnectingTryAgain =>
      'Reconnecting to the room — try again in a moment';

  @override
  String get stillConnecting => 'Still connecting to the room';

  @override
  String waitingForReconnectShort(String names) {
    return 'Waiting for $names to reconnect';
  }

  @override
  String get waitingForAdBreak => 'Waiting for the ad break to finish';

  @override
  String waitingForAdShort(String names) {
    return 'Waiting for $names to finish an ad';
  }

  @override
  String get couldNotReachReaders => 'Could not reach the other readers';

  @override
  String get couldNotSendAnswer => 'Could not send your answer. Try again.';

  @override
  String get turnRequestExpired => 'The page turn request expired';

  @override
  String turnTimedOutWaitingFor(String names) {
    return 'Page turn timed out waiting for $names';
  }

  @override
  String othersNeedAppUpdate(String names, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'need',
      one: 'needs',
    );
    return '$names $_temp0 to update the app to read together';
  }

  @override
  String updateAppToReadWith(String names) {
    return 'Update the app to read with $names';
  }

  @override
  String get sentenceSeparator => '. ';

  @override
  String get cancelTimeout =>
      'Page turn timed out waiting for the other readers';

  @override
  String get cancelOutOfSync =>
      'Readers were on different pages. Synced — try again';

  @override
  String get cancelRequesterLeft => 'Page turn cancelled: the requester left';

  @override
  String get cancelSuperseded => 'Another page turn went first';

  @override
  String get cancelTurnFailed =>
      'The page did not move — this may be the start or end of the book';

  @override
  String get cancelJumpFailed => 'Could not go to that page — try again';

  @override
  String get cancelRequesterBusy =>
      'Page turn cancelled: the page was still loading';

  @override
  String get cancelReaderDisconnected =>
      'Page turn paused: a reader is reconnecting';

  @override
  String get cancelAdBreak => 'Page turn paused: the ad break is not over yet';

  @override
  String get readerAskedToWait => 'A reader asked to wait on this page';

  @override
  String nicknameAskedToWait(String nickname) {
    return '$nickname asked to wait on this page';
  }

  @override
  String get turnCancelled => 'Page turn cancelled';

  @override
  String othersNeedUpdateToJump(String names, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'need',
      one: 'needs',
    );
    return '$names $_temp0 to update the app to jump to a page';
  }

  @override
  String get waitingForTheBookEllipsis => 'Waiting for the book...';

  @override
  String get bookArrivedDamaged => 'The book arrived damaged. Asking again...';

  @override
  String get downloadingFromLibrary =>
      'Downloading the book from the library...';

  @override
  String gettingBookFrom(String nickname) {
    return 'Getting the book from $nickname...';
  }

  @override
  String get waitingForHolder =>
      'Waiting for someone with the book to come online...';

  @override
  String askingForBook(String nickname) {
    return 'Asking $nickname for the book...';
  }

  @override
  String get anotherReader => 'another reader';

  @override
  String get aReader => 'A reader';

  @override
  String get switchLanguage => '中文';

  @override
  String get switchLanguageTooltip => 'Switch to Chinese';

  @override
  String get txtNeedsTitle => 'The book needs a title.';

  @override
  String get txtPickAtLeastOne => 'Pick at least one TXT file.';

  @override
  String get txtNoText => 'These files have no text in them.';

  @override
  String cannotReadFile(String fileName) {
    return 'Cannot read $fileName';
  }
}
