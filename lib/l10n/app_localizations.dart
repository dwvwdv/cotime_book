import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// The app name in the window and task switcher.
  ///
  /// In en, this message translates to:
  /// **'CoTime Book'**
  String get appName;

  /// No description provided for @mastheadTagline.
  ///
  /// In en, this message translates to:
  /// **'Read together, anywhere'**
  String get mastheadTagline;

  /// No description provided for @pressBackAgainToExit.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get pressBackAgainToExit;

  /// No description provided for @activeRoom.
  ///
  /// In en, this message translates to:
  /// **'Active room'**
  String get activeRoom;

  /// No description provided for @continueAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueAction;

  /// No description provided for @leaving.
  ///
  /// In en, this message translates to:
  /// **'Leaving...'**
  String get leaving;

  /// No description provided for @leaveRoom.
  ///
  /// In en, this message translates to:
  /// **'Leave Room'**
  String get leaveRoom;

  /// No description provided for @nickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nickname;

  /// No description provided for @nicknameHint.
  ///
  /// In en, this message translates to:
  /// **'What should others call you?'**
  String get nicknameHint;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @joining.
  ///
  /// In en, this message translates to:
  /// **'Joining...'**
  String get joining;

  /// No description provided for @joinRoom.
  ///
  /// In en, this message translates to:
  /// **'Join Room'**
  String get joinRoom;

  /// No description provided for @creating.
  ///
  /// In en, this message translates to:
  /// **'Creating...'**
  String get creating;

  /// No description provided for @createRoom.
  ///
  /// In en, this message translates to:
  /// **'Create Room'**
  String get createRoom;

  /// No description provided for @supabaseNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Supabase not configured.\nRun with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...'**
  String get supabaseNotConfigured;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// No description provided for @tapToConnect.
  ///
  /// In en, this message translates to:
  /// **'Tap to connect'**
  String get tapToConnect;

  /// No description provided for @enterNickname.
  ///
  /// In en, this message translates to:
  /// **'Please enter a nickname'**
  String get enterNickname;

  /// No description provided for @leaveBeforeCreating.
  ///
  /// In en, this message translates to:
  /// **'Leave the active room before creating another one.'**
  String get leaveBeforeCreating;

  /// No description provided for @enterValidRoomCode.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid 6-character room code'**
  String get enterValidRoomCode;

  /// No description provided for @leaveBeforeJoining.
  ///
  /// In en, this message translates to:
  /// **'Leave the active room before joining another one.'**
  String get leaveBeforeJoining;

  /// No description provided for @cleanupRoomMembership.
  ///
  /// In en, this message translates to:
  /// **'room membership: {error}'**
  String cleanupRoomMembership(String error);

  /// No description provided for @cleanupRealtimePresence.
  ///
  /// In en, this message translates to:
  /// **'realtime presence: {error}'**
  String cleanupRealtimePresence(String error);

  /// No description provided for @roomCleanupNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Room cleanup needs attention: {errors}'**
  String roomCleanupNeedsAttention(String errors);

  /// No description provided for @txtToEpub.
  ///
  /// In en, this message translates to:
  /// **'TXT to EPUB'**
  String get txtToEpub;

  /// No description provided for @moreApps.
  ///
  /// In en, this message translates to:
  /// **'More Apps'**
  String get moreApps;

  /// No description provided for @news.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get news;

  /// No description provided for @txtConvertIntro.
  ///
  /// In en, this message translates to:
  /// **'Make an EPUB from TXT files and read it here to check the text and chapters. Save it once it looks right, then share the saved EPUB in a room.'**
  String get txtConvertIntro;

  /// No description provided for @pickTxtFiles.
  ///
  /// In en, this message translates to:
  /// **'Pick TXT Files'**
  String get pickTxtFiles;

  /// No description provided for @converted.
  ///
  /// In en, this message translates to:
  /// **'Converted'**
  String get converted;

  /// No description provided for @read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving...'**
  String get saving;

  /// No description provided for @saveAgain.
  ///
  /// In en, this message translates to:
  /// **'Save Again'**
  String get saveAgain;

  /// No description provided for @saveEpub.
  ///
  /// In en, this message translates to:
  /// **'Save EPUB'**
  String get saveEpub;

  /// No description provided for @savedShareInRoom.
  ///
  /// In en, this message translates to:
  /// **'Saved. In a room, tap Share Book and pick this file.'**
  String get savedShareInRoom;

  /// No description provided for @convertOtherFiles.
  ///
  /// In en, this message translates to:
  /// **'Convert Other Files'**
  String get convertOtherFiles;

  /// No description provided for @opening.
  ///
  /// In en, this message translates to:
  /// **'Opening...'**
  String get opening;

  /// No description provided for @reading.
  ///
  /// In en, this message translates to:
  /// **'Reading...'**
  String get reading;

  /// No description provided for @converting.
  ///
  /// In en, this message translates to:
  /// **'Converting...'**
  String get converting;

  /// No description provided for @pickOnlyTxt.
  ///
  /// In en, this message translates to:
  /// **'Pick only TXT files. An EPUB needs no converting: share it in a room as it is.'**
  String get pickOnlyTxt;

  /// No description provided for @txtSourcesTooLarge.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This file is} other{These files are}} {size}. A book can be made of at most {limit} of text.'**
  String txtSourcesTooLarge(int count, String size, String limit);

  /// No description provided for @convertedBookTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The book came out at {size}. Books can be at most {limit}.'**
  String convertedBookTooLarge(String size, String limit);

  /// No description provided for @couldNotSaveEpub.
  ///
  /// In en, this message translates to:
  /// **'Could not save the EPUB: {error}'**
  String couldNotSaveEpub(String error);

  /// No description provided for @roomNotOnDevice.
  ///
  /// In en, this message translates to:
  /// **'This room is not available on this device.'**
  String get roomNotOnDevice;

  /// No description provided for @roomLinkMismatch.
  ///
  /// In en, this message translates to:
  /// **'Room link {link} does not match your active room {code}.'**
  String roomLinkMismatch(String link, String code);

  /// No description provided for @unknownBook.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknownBook;

  /// No description provided for @roomClosed.
  ///
  /// In en, this message translates to:
  /// **'This room has been closed.'**
  String get roomClosed;

  /// No description provided for @roomInitCancelled.
  ///
  /// In en, this message translates to:
  /// **'Room initialization was cancelled.'**
  String get roomInitCancelled;

  /// No description provided for @authTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Authentication timed out. Please return home and retry.'**
  String get authTimedOut;

  /// No description provided for @openingRoom.
  ///
  /// In en, this message translates to:
  /// **'Opening the room...'**
  String get openingRoom;

  /// No description provided for @roomNoLongerAvailable.
  ///
  /// In en, this message translates to:
  /// **'This room is no longer available.'**
  String get roomNoLongerAvailable;

  /// No description provided for @roomLobby.
  ///
  /// In en, this message translates to:
  /// **'Room Lobby'**
  String get roomLobby;

  /// No description provided for @leaveRoomTooltip.
  ///
  /// In en, this message translates to:
  /// **'Leave room'**
  String get leaveRoomTooltip;

  /// No description provided for @roomCodeOverline.
  ///
  /// In en, this message translates to:
  /// **'ROOM CODE'**
  String get roomCodeOverline;

  /// No description provided for @members.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get members;

  /// No description provided for @onlineCount.
  ///
  /// In en, this message translates to:
  /// **'{count} online'**
  String onlineCount(int count);

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @shareBook.
  ///
  /// In en, this message translates to:
  /// **'Share Book'**
  String get shareBook;

  /// No description provided for @library.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// No description provided for @startReading.
  ///
  /// In en, this message translates to:
  /// **'Start Reading'**
  String get startReading;

  /// No description provided for @joinReading.
  ///
  /// In en, this message translates to:
  /// **'Join Reading'**
  String get joinReading;

  /// No description provided for @reconnectingToRoom.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to the room...'**
  String get reconnectingToRoom;

  /// No description provided for @onlyHostCanStart.
  ///
  /// In en, this message translates to:
  /// **'Only the room host can start reading.'**
  String get onlyHostCanStart;

  /// No description provided for @unableToStartReading.
  ///
  /// In en, this message translates to:
  /// **'Unable to start reading: {error}'**
  String unableToStartReading(String error);

  /// No description provided for @readingStartedWaitForBook.
  ///
  /// In en, this message translates to:
  /// **'Reading has started. You can join as soon as the book arrives.'**
  String get readingStartedWaitForBook;

  /// No description provided for @bookNotOnDevice.
  ///
  /// In en, this message translates to:
  /// **'The book is not on this device yet.'**
  String get bookNotOnDevice;

  /// No description provided for @roomUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Room unavailable'**
  String get roomUnavailable;

  /// No description provided for @returnHome.
  ///
  /// In en, this message translates to:
  /// **'Return Home'**
  String get returnHome;

  /// No description provided for @readyToRead.
  ///
  /// In en, this message translates to:
  /// **'Ready to read'**
  String get readyToRead;

  /// No description provided for @receivingBook.
  ///
  /// In en, this message translates to:
  /// **'Receiving book...'**
  String get receivingBook;

  /// No description provided for @appOutOfDate.
  ///
  /// In en, this message translates to:
  /// **'Your app is out of date: {names} {count, plural, =1{is} other{are}} on a newer version. Update {appName} to read together.'**
  String appOutOfDate(String names, int count, String appName);

  /// No description provided for @othersNeedUpdate.
  ///
  /// In en, this message translates to:
  /// **'{names} {count, plural, =1{needs} other{need}} to update {appName} to read together.'**
  String othersNeedUpdate(String names, int count, String appName);

  /// No description provided for @shareBookToStart.
  ///
  /// In en, this message translates to:
  /// **'Share a book to start reading.'**
  String get shareBookToStart;

  /// No description provided for @waitingForBookShare.
  ///
  /// In en, this message translates to:
  /// **'Waiting for someone to share a book.'**
  String get waitingForBookShare;

  /// No description provided for @bookOnItsWay.
  ///
  /// In en, this message translates to:
  /// **'The book is on its way to this device.'**
  String get bookOnItsWay;

  /// No description provided for @connectingToRoom.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the room...'**
  String get connectingToRoom;

  /// No description provided for @hostStartsSession.
  ///
  /// In en, this message translates to:
  /// **'The host starts the reading session.'**
  String get hostStartsSession;

  /// No description provided for @stillReceivingBook.
  ///
  /// In en, this message translates to:
  /// **'{names} {count, plural, =1{is} other{are}} still receiving the book and can join when it arrives.'**
  String stillReceivingBook(String names, int count);

  /// Joins names in a list.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get listSeparator;

  /// No description provided for @themePaper.
  ///
  /// In en, this message translates to:
  /// **'Paper'**
  String get themePaper;

  /// No description provided for @themeNight.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get themeNight;

  /// No description provided for @themeSepia.
  ///
  /// In en, this message translates to:
  /// **'Sepia'**
  String get themeSepia;

  /// No description provided for @couldNotChangeTextSize.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change the room\'s text size. Try again in a moment.'**
  String get couldNotChangeTextSize;

  /// No description provided for @reader.
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get reader;

  /// No description provided for @openingBook.
  ///
  /// In en, this message translates to:
  /// **'Opening the book...'**
  String get openingBook;

  /// No description provided for @noBookLoaded.
  ///
  /// In en, this message translates to:
  /// **'No book loaded'**
  String get noBookLoaded;

  /// No description provided for @backToLobby.
  ///
  /// In en, this message translates to:
  /// **'Back to Lobby'**
  String get backToLobby;

  /// No description provided for @leaveReading.
  ///
  /// In en, this message translates to:
  /// **'Leave reading'**
  String get leaveReading;

  /// No description provided for @readingSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reading settings'**
  String get readingSettingsTooltip;

  /// No description provided for @readingSettings.
  ///
  /// In en, this message translates to:
  /// **'Reading Settings'**
  String get readingSettings;

  /// No description provided for @settingsPage.
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get settingsPage;

  /// No description provided for @settingsTextSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get settingsTextSize;

  /// No description provided for @textSizeTakesSeconds.
  ///
  /// In en, this message translates to:
  /// **'A new text size takes a few seconds to show: the book is laid out again on every reader\'s screen. Wait for the page to change before tapping again or turning.'**
  String get textSizeTakesSeconds;

  /// No description provided for @onlyISetTextSize.
  ///
  /// In en, this message translates to:
  /// **'Only I set the text size'**
  String get onlyISetTextSize;

  /// No description provided for @onlyISetTextSizeHint.
  ///
  /// In en, this message translates to:
  /// **'Turn off to let everyone pick a size. The room then reads at the largest size anyone picked.'**
  String get onlyISetTextSizeHint;

  /// No description provided for @settingsTurningPages.
  ///
  /// In en, this message translates to:
  /// **'Turning pages'**
  String get settingsTurningPages;

  /// No description provided for @volumeKeysTurnPages.
  ///
  /// In en, this message translates to:
  /// **'Volume keys turn pages'**
  String get volumeKeysTurnPages;

  /// No description provided for @volumeKeysTurnPagesHint.
  ///
  /// In en, this message translates to:
  /// **'For e-readers whose page buttons act as volume keys.'**
  String get volumeKeysTurnPagesHint;

  /// No description provided for @tapZonesHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the left third of the page to go back, anywhere else to go forward. Page Up/Down and arrow keys work too.'**
  String get tapZonesHint;

  /// No description provided for @settingsTroubleshooting.
  ///
  /// In en, this message translates to:
  /// **'Troubleshooting'**
  String get settingsTroubleshooting;

  /// No description provided for @pageLayoutReport.
  ///
  /// In en, this message translates to:
  /// **'Page Layout Report'**
  String get pageLayoutReport;

  /// No description provided for @themeOptionLabel.
  ///
  /// In en, this message translates to:
  /// **'{theme} theme'**
  String themeOptionLabel(String theme);

  /// No description provided for @youSetTextSize.
  ///
  /// In en, this message translates to:
  /// **'You set the text size for everyone in this room.'**
  String get youSetTextSize;

  /// No description provided for @hostSetsTextSize.
  ///
  /// In en, this message translates to:
  /// **'The host sets the text size in this room.'**
  String get hostSetsTextSize;

  /// No description provided for @everyoneSeesSamePage.
  ///
  /// In en, this message translates to:
  /// **'Everyone sees the same page: it fits the smallest screen in the room, at the largest text size anyone picked.'**
  String get everyoneSeesSamePage;

  /// No description provided for @anotherReaderPickedSize.
  ///
  /// In en, this message translates to:
  /// **'Another reader picked {size}, so the room reads at {size}. {shared}'**
  String anotherReaderPickedSize(int size, String shared);

  /// No description provided for @roomMembers.
  ///
  /// In en, this message translates to:
  /// **'Room members'**
  String get roomMembers;

  /// No description provided for @waitingForReconnect.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {names} to reconnect...'**
  String waitingForReconnect(String names);

  /// No description provided for @adBreakEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Ad break...'**
  String get adBreakEllipsis;

  /// No description provided for @adBreakWaitingFor.
  ///
  /// In en, this message translates to:
  /// **'Ad break: waiting for {names}...'**
  String adBreakWaitingFor(String names);

  /// No description provided for @readersReady.
  ///
  /// In en, this message translates to:
  /// **'{count} readers ready'**
  String readersReady(int count);

  /// No description provided for @synced.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get synced;

  /// No description provided for @waitingForNames.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {names}...'**
  String waitingForNames(String names);

  /// No description provided for @wait.
  ///
  /// In en, this message translates to:
  /// **'Wait'**
  String get wait;

  /// No description provided for @go.
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get go;

  /// No description provided for @turn.
  ///
  /// In en, this message translates to:
  /// **'Turn'**
  String get turn;

  /// No description provided for @waitingForOthersToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Waiting for others to confirm... {confirmed}/{required}'**
  String waitingForOthersToConfirm(int confirmed, int required);

  /// No description provided for @jumpingToPage.
  ///
  /// In en, this message translates to:
  /// **'Jumping to the page...'**
  String get jumpingToPage;

  /// No description provided for @turningPage.
  ///
  /// In en, this message translates to:
  /// **'Turning page...'**
  String get turningPage;

  /// No description provided for @unknownMember.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknownMember;

  /// No description provided for @wantsNextPage.
  ///
  /// In en, this message translates to:
  /// **'{who} wants to go to next page'**
  String wantsNextPage(String who);

  /// No description provided for @wantsPreviousPage.
  ///
  /// In en, this message translates to:
  /// **'{who} wants to go to previous page'**
  String wantsPreviousPage(String who);

  /// No description provided for @wantsJumpElsewhere.
  ///
  /// In en, this message translates to:
  /// **'{who} wants to jump to another page'**
  String wantsJumpElsewhere(String who);

  /// No description provided for @wantsJumpToPage.
  ///
  /// In en, this message translates to:
  /// **'{who} wants to jump to page {page}'**
  String wantsJumpToPage(String who, String page);

  /// No description provided for @wantsJumpToPageWithProgress.
  ///
  /// In en, this message translates to:
  /// **'{who} wants to jump to page {page} ({progress})'**
  String wantsJumpToPageWithProgress(String who, String page, String progress);

  /// No description provided for @askToLeaveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Ask {nickname} to leave'**
  String askToLeaveTooltip(String nickname);

  /// No description provided for @askToLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Ask {nickname} to leave?'**
  String askToLeaveTitle(String nickname);

  /// No description provided for @askToLeaveMessage.
  ///
  /// In en, this message translates to:
  /// **'{nickname} will be taken out of the room, and nobody waits for them to turn the page. They can join again with the room code.\n\nIf others are here too, more than half of you have to agree.'**
  String askToLeaveMessage(String nickname);

  /// No description provided for @askToLeave.
  ///
  /// In en, this message translates to:
  /// **'Ask to leave'**
  String get askToLeave;

  /// No description provided for @removeMemberTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {nickname}?'**
  String removeMemberTitle(String nickname);

  /// No description provided for @voteIsOver.
  ///
  /// In en, this message translates to:
  /// **'This vote is over.'**
  String get voteIsOver;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @removalVoteMessage.
  ///
  /// In en, this message translates to:
  /// **'{voter} asked {target} to leave the room, so nobody waits for them to turn the page. {target} can join again with the room code.'**
  String removalVoteMessage(String voter, String target);

  /// No description provided for @moreVotesNeeded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more vote needed.} other{{count} more votes needed.}}'**
  String moreVotesNeeded(int count);

  /// No description provided for @agree.
  ///
  /// In en, this message translates to:
  /// **'Agree'**
  String get agree;

  /// No description provided for @notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No description provided for @couldNotAskToLeave.
  ///
  /// In en, this message translates to:
  /// **'Could not ask {nickname} to leave. Try again.'**
  String couldNotAskToLeave(String nickname);

  /// No description provided for @memberRemoved.
  ///
  /// In en, this message translates to:
  /// **'{nickname} was removed from the room.'**
  String memberRemoved(String nickname);

  /// No description provided for @memberGone.
  ///
  /// In en, this message translates to:
  /// **'{nickname} is no longer in the room.'**
  String memberGone(String nickname);

  /// No description provided for @voteIn.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Your vote is in. 1 more vote needed to remove {nickname}.} other{Your vote is in. {count} more votes needed to remove {nickname}.}}'**
  String voteIn(int count, String nickname);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @noMembersYet.
  ///
  /// In en, this message translates to:
  /// **'No members yet'**
  String get noMembersYet;

  /// No description provided for @needsAppUpdate.
  ///
  /// In en, this message translates to:
  /// **'Needs app update'**
  String get needsAppUpdate;

  /// No description provided for @newerAppUpdateYours.
  ///
  /// In en, this message translates to:
  /// **'Newer app — update yours'**
  String get newerAppUpdateYours;

  /// No description provided for @youSuffix.
  ///
  /// In en, this message translates to:
  /// **'  (You)'**
  String get youSuffix;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @awayNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Away — not connected'**
  String get awayNotConnected;

  /// No description provided for @hasBook.
  ///
  /// In en, this message translates to:
  /// **'Has book'**
  String get hasBook;

  /// No description provided for @noBook.
  ///
  /// In en, this message translates to:
  /// **'No book'**
  String get noBook;

  /// No description provided for @membersOnline.
  ///
  /// In en, this message translates to:
  /// **'{count} Members Online'**
  String membersOnline(int count);

  /// No description provided for @statusReading.
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get statusReading;

  /// No description provided for @statusLeftReader.
  ///
  /// In en, this message translates to:
  /// **'Left the reader'**
  String get statusLeftReader;

  /// No description provided for @statusNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get statusNotConnected;

  /// No description provided for @adBreakPageOpensWhenBack.
  ///
  /// In en, this message translates to:
  /// **'The page opens when every reader is back.'**
  String get adBreakPageOpensWhenBack;

  /// No description provided for @adBreakWaitingForAd.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {names} to finish an ad...'**
  String adBreakWaitingForAd(String names);

  /// No description provided for @adBreak.
  ///
  /// In en, this message translates to:
  /// **'Ad break'**
  String get adBreak;

  /// No description provided for @ads.
  ///
  /// In en, this message translates to:
  /// **'Ads'**
  String get ads;

  /// No description provided for @adPrivacyChoices.
  ///
  /// In en, this message translates to:
  /// **'Ad Privacy Choices'**
  String get adPrivacyChoices;

  /// No description provided for @adPrivacyChoicesHint.
  ///
  /// In en, this message translates to:
  /// **'Change what you agreed to for the ads in this app.'**
  String get adPrivacyChoicesHint;

  /// No description provided for @announcementsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The announcements could not be loaded.'**
  String get announcementsLoadFailed;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get tryAgain;

  /// No description provided for @noAnnouncements.
  ///
  /// In en, this message translates to:
  /// **'No announcements yet.'**
  String get noAnnouncements;

  /// No description provided for @contents.
  ///
  /// In en, this message translates to:
  /// **'Contents'**
  String get contents;

  /// No description provided for @contentsEntries.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 entry} other{{count} entries}}'**
  String contentsEntries(int count);

  /// No description provided for @noContents.
  ///
  /// In en, this message translates to:
  /// **'This book has no contents.'**
  String get noContents;

  /// No description provided for @untitled.
  ///
  /// In en, this message translates to:
  /// **'(untitled)'**
  String get untitled;

  /// No description provided for @stillWorkingOutLength.
  ///
  /// In en, this message translates to:
  /// **'Still working out the length of the book. Try again in a moment.'**
  String get stillWorkingOutLength;

  /// No description provided for @jumpPageLabel.
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get jumpPageLabel;

  /// No description provided for @jumpHere.
  ///
  /// In en, this message translates to:
  /// **'Here'**
  String get jumpHere;

  /// No description provided for @previousPage.
  ///
  /// In en, this message translates to:
  /// **'Previous page'**
  String get previousPage;

  /// No description provided for @nextPage.
  ///
  /// In en, this message translates to:
  /// **'Next page'**
  String get nextPage;

  /// No description provided for @positionInBook.
  ///
  /// In en, this message translates to:
  /// **'Position in the book'**
  String get positionInBook;

  /// No description provided for @reportRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many reports in the last hour. Copy this one instead.'**
  String get reportRateLimited;

  /// No description provided for @reportSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t send the report. Try again, or copy it instead.'**
  String get reportSendFailed;

  /// No description provided for @pageLayoutReportTitle.
  ///
  /// In en, this message translates to:
  /// **'Page layout report'**
  String get pageLayoutReportTitle;

  /// No description provided for @pageLayoutReportIntro.
  ///
  /// In en, this message translates to:
  /// **'If pages are cut off or a turn skips ahead, send this right after it happens. It holds how this screen laid out the page and where you are in the book, never the book\'s text.'**
  String get pageLayoutReportIntro;

  /// No description provided for @reportNoteHint.
  ///
  /// In en, this message translates to:
  /// **'What went wrong? (optional)'**
  String get reportNoteHint;

  /// No description provided for @reportSent.
  ///
  /// In en, this message translates to:
  /// **'Sent. Report ID: {id}'**
  String reportSent(String id);

  /// No description provided for @sending.
  ///
  /// In en, this message translates to:
  /// **'Sending...'**
  String get sending;

  /// No description provided for @sendReport.
  ///
  /// In en, this message translates to:
  /// **'Send Report'**
  String get sendReport;

  /// No description provided for @reportCopied.
  ///
  /// In en, this message translates to:
  /// **'Report copied'**
  String get reportCopied;

  /// No description provided for @copyReport.
  ///
  /// In en, this message translates to:
  /// **'Copy Report'**
  String get copyReport;

  /// No description provided for @languageChineseTraditional.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Traditional)'**
  String get languageChineseTraditional;

  /// No description provided for @languageChineseSimplified.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified)'**
  String get languageChineseSimplified;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageJapanese.
  ///
  /// In en, this message translates to:
  /// **'Japanese'**
  String get languageJapanese;

  /// No description provided for @languageKorean.
  ///
  /// In en, this message translates to:
  /// **'Korean'**
  String get languageKorean;

  /// No description provided for @languageFrench.
  ///
  /// In en, this message translates to:
  /// **'French'**
  String get languageFrench;

  /// No description provided for @languageGerman.
  ///
  /// In en, this message translates to:
  /// **'German'**
  String get languageGerman;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get languageSpanish;

  /// No description provided for @languageItalian.
  ///
  /// In en, this message translates to:
  /// **'Italian'**
  String get languageItalian;

  /// No description provided for @languagePortuguese.
  ///
  /// In en, this message translates to:
  /// **'Portuguese'**
  String get languagePortuguese;

  /// No description provided for @languageRussian.
  ///
  /// In en, this message translates to:
  /// **'Russian'**
  String get languageRussian;

  /// No description provided for @languageLatin.
  ///
  /// In en, this message translates to:
  /// **'Latin'**
  String get languageLatin;

  /// No description provided for @languageGreek.
  ///
  /// In en, this message translates to:
  /// **'Greek'**
  String get languageGreek;

  /// No description provided for @languageDutch.
  ///
  /// In en, this message translates to:
  /// **'Dutch'**
  String get languageDutch;

  /// No description provided for @languageVietnamese.
  ///
  /// In en, this message translates to:
  /// **'Vietnamese'**
  String get languageVietnamese;

  /// No description provided for @languageThai.
  ///
  /// In en, this message translates to:
  /// **'Thai'**
  String get languageThai;

  /// No description provided for @libraryOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'The library could not be opened.'**
  String get libraryOpenFailed;

  /// No description provided for @libraryNoteLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The note could not be loaded.'**
  String get libraryNoteLoadFailed;

  /// No description provided for @publicLibrary.
  ///
  /// In en, this message translates to:
  /// **'Public Library'**
  String get publicLibrary;

  /// No description provided for @aboutTheseBooks.
  ///
  /// In en, this message translates to:
  /// **'About these books'**
  String get aboutTheseBooks;

  /// No description provided for @searchByTitleOrAuthor.
  ///
  /// In en, this message translates to:
  /// **'Search by title or author'**
  String get searchByTitleOrAuthor;

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// No description provided for @books.
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get books;

  /// No description provided for @bookCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 book} other{{count} books}}'**
  String bookCount(int count);

  /// No description provided for @shownOfBooks.
  ///
  /// In en, this message translates to:
  /// **'{shown} of {total}'**
  String shownOfBooks(int shown, String total);

  /// No description provided for @loadingLibrary.
  ///
  /// In en, this message translates to:
  /// **'Loading the library...'**
  String get loadingLibrary;

  /// No description provided for @libraryEmpty.
  ///
  /// In en, this message translates to:
  /// **'The library is empty for now.'**
  String get libraryEmpty;

  /// No description provided for @noBooksMatch.
  ///
  /// In en, this message translates to:
  /// **'No books match.'**
  String get noBooksMatch;

  /// No description provided for @clearSearchAndFilters.
  ///
  /// In en, this message translates to:
  /// **'Clear Search and Filters'**
  String get clearSearchAndFilters;

  /// No description provided for @filters.
  ///
  /// In en, this message translates to:
  /// **'Filters'**
  String get filters;

  /// No description provided for @tags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tags;

  /// No description provided for @booksWithAnyTag.
  ///
  /// In en, this message translates to:
  /// **'Books with any of them'**
  String get booksWithAnyTag;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @noNoteYet.
  ///
  /// In en, this message translates to:
  /// **'No note has been written yet.'**
  String get noNoteYet;

  /// No description provided for @aboutTheseBooksOverline.
  ///
  /// In en, this message translates to:
  /// **'ABOUT THESE BOOKS'**
  String get aboutTheseBooksOverline;

  /// No description provided for @getItOnGooglePlay.
  ///
  /// In en, this message translates to:
  /// **'Get it on Google Play'**
  String get getItOnGooglePlay;

  /// No description provided for @googlePlayCouldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'Google Play could not be opened on this device. The link:'**
  String get googlePlayCouldNotOpen;

  /// No description provided for @goToPage.
  ///
  /// In en, this message translates to:
  /// **'Go to page'**
  String get goToPage;

  /// No description provided for @pageCounterLabel.
  ///
  /// In en, this message translates to:
  /// **'Page {page} of {pages} in this chapter'**
  String pageCounterLabel(int page, int pages);

  /// No description provided for @pageCounterProgress.
  ///
  /// In en, this message translates to:
  /// **', {progress} of the book'**
  String pageCounterProgress(String progress);

  /// No description provided for @pageCounterGoTo.
  ///
  /// In en, this message translates to:
  /// **'. Go to page'**
  String get pageCounterGoTo;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @recentRooms.
  ///
  /// In en, this message translates to:
  /// **'Recent rooms'**
  String get recentRooms;

  /// No description provided for @noBookYet.
  ///
  /// In en, this message translates to:
  /// **'No book yet'**
  String get noBookYet;

  /// No description provided for @recentRoomSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{book} · {visit}'**
  String recentRoomSubtitle(String book, String visit);

  /// No description provided for @removeFromRecentRooms.
  ///
  /// In en, this message translates to:
  /// **'Remove {code} from recent rooms'**
  String removeFromRecentRooms(String code);

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days} days ago'**
  String daysAgo(int days);

  /// No description provided for @roomCodeSemantics.
  ///
  /// In en, this message translates to:
  /// **'Room code {code}. Tap to copy.'**
  String roomCodeSemantics(String code);

  /// No description provided for @roomCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Room code copied'**
  String get roomCodeCopied;

  /// No description provided for @tapToCopy.
  ///
  /// In en, this message translates to:
  /// **'Tap to copy'**
  String get tapToCopy;

  /// No description provided for @roomCode.
  ///
  /// In en, this message translates to:
  /// **'Room code'**
  String get roomCode;

  /// No description provided for @waitingForTheBook.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the book'**
  String get waitingForTheBook;

  /// No description provided for @sendingBook.
  ///
  /// In en, this message translates to:
  /// **'Sending book...'**
  String get sendingBook;

  /// No description provided for @bookSent.
  ///
  /// In en, this message translates to:
  /// **'Book sent'**
  String get bookSent;

  /// No description provided for @bookReceived.
  ///
  /// In en, this message translates to:
  /// **'Book received'**
  String get bookReceived;

  /// No description provided for @missedPartsWillAsk.
  ///
  /// In en, this message translates to:
  /// **'Anyone who missed part of it will ask for the rest.'**
  String get missedPartsWillAsk;

  /// No description provided for @readyToReadSentence.
  ///
  /// In en, this message translates to:
  /// **'Ready to read.'**
  String get readyToReadSentence;

  /// No description provided for @makeBookFromTxt.
  ///
  /// In en, this message translates to:
  /// **'Make a book from TXT'**
  String get makeBookFromTxt;

  /// No description provided for @txtFilesBecomeOneEpub.
  ///
  /// In en, this message translates to:
  /// **'These {count} files become one EPUB, in this order. You can read it before saving it.'**
  String txtFilesBecomeOneEpub(int count);

  /// No description provided for @txtFileBecomesEpub.
  ///
  /// In en, this message translates to:
  /// **'This file becomes an EPUB. You can read it before saving it.'**
  String get txtFileBecomesEpub;

  /// No description provided for @title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// No description provided for @authorOptional.
  ///
  /// In en, this message translates to:
  /// **'Author (optional)'**
  String get authorOptional;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @splitByLength.
  ///
  /// In en, this message translates to:
  /// **'Split by length'**
  String get splitByLength;

  /// No description provided for @noChaptersFound.
  ///
  /// In en, this message translates to:
  /// **'No chapters found'**
  String get noChaptersFound;

  /// No description provided for @chapterCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chapter} other{{count} chapters}}'**
  String chapterCount(int count);

  /// No description provided for @splitIntoChapters.
  ///
  /// In en, this message translates to:
  /// **'Split into chapters'**
  String get splitIntoChapters;

  /// No description provided for @splitIntoChaptersHint.
  ///
  /// In en, this message translates to:
  /// **'Turn off if lines that are not chapter titles were taken for them. The book is then split by length.'**
  String get splitIntoChaptersHint;

  /// No description provided for @makeEpub.
  ///
  /// In en, this message translates to:
  /// **'Make EPUB'**
  String get makeEpub;

  /// No description provided for @noTextInEncoding.
  ///
  /// In en, this message translates to:
  /// **'No text in this encoding; it will be skipped'**
  String get noTextInEncoding;

  /// No description provided for @characterCount.
  ///
  /// In en, this message translates to:
  /// **'{count} characters'**
  String characterCount(String count);

  /// No description provided for @splitByLengthWithCharacters.
  ///
  /// In en, this message translates to:
  /// **'Split by length · {characters}'**
  String splitByLengthWithCharacters(String characters);

  /// No description provided for @noChapterHeadingsWithCharacters.
  ///
  /// In en, this message translates to:
  /// **'No chapter headings, split by length · {characters}'**
  String noChapterHeadingsWithCharacters(String characters);

  /// No description provided for @chaptersWithCharacters.
  ///
  /// In en, this message translates to:
  /// **'{chapters} · {characters}'**
  String chaptersWithCharacters(String chapters, String characters);

  /// No description provided for @textEncoding.
  ///
  /// In en, this message translates to:
  /// **'Text encoding'**
  String get textEncoding;

  /// No description provided for @encodingLabel.
  ///
  /// In en, this message translates to:
  /// **'Encoding: {encoding}'**
  String encodingLabel(String encoding);

  /// No description provided for @moveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get moveUp;

  /// No description provided for @moveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get moveDown;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @onlyYouSeeThis.
  ///
  /// In en, this message translates to:
  /// **'Only you see this · {percent}%'**
  String onlyYouSeeThis(int percent);

  /// No description provided for @pageNotFound.
  ///
  /// In en, this message translates to:
  /// **'Page not found: {uri}'**
  String pageNotFound(String uri);

  /// No description provided for @invalidRoomLink.
  ///
  /// In en, this message translates to:
  /// **'Invalid room link'**
  String get invalidRoomLink;

  /// No description provided for @joinFromHomeFirst.
  ///
  /// In en, this message translates to:
  /// **'Join this room from Home before opening this page.'**
  String get joinFromHomeFirst;

  /// No description provided for @notEpub.
  ///
  /// In en, this message translates to:
  /// **'Only EPUB books can be shared. Make a TXT file into one with \"TXT to EPUB\" on the home screen first.'**
  String get notEpub;

  /// No description provided for @libraryDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not get \"{title}\" from the library: {error}'**
  String libraryDownloadFailed(String title, String error);

  /// No description provided for @bookFileEmpty.
  ///
  /// In en, this message translates to:
  /// **'The book file is empty'**
  String get bookFileEmpty;

  /// No description provided for @bookTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This book is {size}. Books can be at most {limit}.'**
  String bookTooLarge(String size, String limit);

  /// No description provided for @membershipInactive.
  ///
  /// In en, this message translates to:
  /// **'This room membership is inactive or has expired.'**
  String get membershipInactive;

  /// No description provided for @roomStateChanged.
  ///
  /// In en, this message translates to:
  /// **'Room state changed before the update could finish'**
  String get roomStateChanged;

  /// No description provided for @roomNoLongerAvailableCode.
  ///
  /// In en, this message translates to:
  /// **'Room {code} is no longer available.'**
  String roomNoLongerAvailableCode(String code);

  /// No description provided for @roomUpdatedByAnotherClient.
  ///
  /// In en, this message translates to:
  /// **'Room state was updated by another client'**
  String get roomUpdatedByAnotherClient;

  /// No description provided for @notAuthenticated.
  ///
  /// In en, this message translates to:
  /// **'Not authenticated'**
  String get notAuthenticated;

  /// No description provided for @removedFromRoom.
  ///
  /// In en, this message translates to:
  /// **'You are no longer in this room. It may have closed, or you left it on another device.'**
  String get removedFromRoom;

  /// No description provided for @removedByVote.
  ///
  /// In en, this message translates to:
  /// **'The other readers removed you from this room. You can join again with the room code.'**
  String get removedByVote;

  /// No description provided for @bookStillLoading.
  ///
  /// In en, this message translates to:
  /// **'The book is still loading'**
  String get bookStillLoading;

  /// No description provided for @reconnectingTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to the room — try again in a moment'**
  String get reconnectingTryAgain;

  /// No description provided for @stillConnecting.
  ///
  /// In en, this message translates to:
  /// **'Still connecting to the room'**
  String get stillConnecting;

  /// No description provided for @waitingForReconnectShort.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {names} to reconnect'**
  String waitingForReconnectShort(String names);

  /// No description provided for @waitingForAdBreak.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the ad break to finish'**
  String get waitingForAdBreak;

  /// No description provided for @waitingForAdShort.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {names} to finish an ad'**
  String waitingForAdShort(String names);

  /// No description provided for @couldNotReachReaders.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the other readers'**
  String get couldNotReachReaders;

  /// No description provided for @couldNotSendAnswer.
  ///
  /// In en, this message translates to:
  /// **'Could not send your answer. Try again.'**
  String get couldNotSendAnswer;

  /// No description provided for @turnRequestExpired.
  ///
  /// In en, this message translates to:
  /// **'The page turn request expired'**
  String get turnRequestExpired;

  /// No description provided for @turnTimedOutWaitingFor.
  ///
  /// In en, this message translates to:
  /// **'Page turn timed out waiting for {names}'**
  String turnTimedOutWaitingFor(String names);

  /// No description provided for @othersNeedAppUpdate.
  ///
  /// In en, this message translates to:
  /// **'{names} {count, plural, =1{needs} other{need}} to update the app to read together'**
  String othersNeedAppUpdate(String names, int count);

  /// No description provided for @updateAppToReadWith.
  ///
  /// In en, this message translates to:
  /// **'Update the app to read with {names}'**
  String updateAppToReadWith(String names);

  /// Joins sentences of one message.
  ///
  /// In en, this message translates to:
  /// **'. '**
  String get sentenceSeparator;

  /// No description provided for @cancelTimeout.
  ///
  /// In en, this message translates to:
  /// **'Page turn timed out waiting for the other readers'**
  String get cancelTimeout;

  /// No description provided for @cancelOutOfSync.
  ///
  /// In en, this message translates to:
  /// **'Readers were on different pages. Synced — try again'**
  String get cancelOutOfSync;

  /// No description provided for @cancelRequesterLeft.
  ///
  /// In en, this message translates to:
  /// **'Page turn cancelled: the requester left'**
  String get cancelRequesterLeft;

  /// No description provided for @cancelSuperseded.
  ///
  /// In en, this message translates to:
  /// **'Another page turn went first'**
  String get cancelSuperseded;

  /// No description provided for @cancelTurnFailed.
  ///
  /// In en, this message translates to:
  /// **'The page did not move — this may be the start or end of the book'**
  String get cancelTurnFailed;

  /// No description provided for @cancelJumpFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not go to that page — try again'**
  String get cancelJumpFailed;

  /// No description provided for @cancelRequesterBusy.
  ///
  /// In en, this message translates to:
  /// **'Page turn cancelled: the page was still loading'**
  String get cancelRequesterBusy;

  /// No description provided for @cancelReaderDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Page turn paused: a reader is reconnecting'**
  String get cancelReaderDisconnected;

  /// No description provided for @cancelAdBreak.
  ///
  /// In en, this message translates to:
  /// **'Page turn paused: the ad break is not over yet'**
  String get cancelAdBreak;

  /// No description provided for @readerAskedToWait.
  ///
  /// In en, this message translates to:
  /// **'A reader asked to wait on this page'**
  String get readerAskedToWait;

  /// No description provided for @nicknameAskedToWait.
  ///
  /// In en, this message translates to:
  /// **'{nickname} asked to wait on this page'**
  String nicknameAskedToWait(String nickname);

  /// No description provided for @turnCancelled.
  ///
  /// In en, this message translates to:
  /// **'Page turn cancelled'**
  String get turnCancelled;

  /// No description provided for @othersNeedUpdateToJump.
  ///
  /// In en, this message translates to:
  /// **'{names} {count, plural, =1{needs} other{need}} to update the app to jump to a page'**
  String othersNeedUpdateToJump(String names, int count);

  /// No description provided for @waitingForTheBookEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the book...'**
  String get waitingForTheBookEllipsis;

  /// No description provided for @bookArrivedDamaged.
  ///
  /// In en, this message translates to:
  /// **'The book arrived damaged. Asking again...'**
  String get bookArrivedDamaged;

  /// No description provided for @downloadingFromLibrary.
  ///
  /// In en, this message translates to:
  /// **'Downloading the book from the library...'**
  String get downloadingFromLibrary;

  /// No description provided for @gettingBookFrom.
  ///
  /// In en, this message translates to:
  /// **'Getting the book from {nickname}...'**
  String gettingBookFrom(String nickname);

  /// No description provided for @waitingForHolder.
  ///
  /// In en, this message translates to:
  /// **'Waiting for someone with the book to come online...'**
  String get waitingForHolder;

  /// No description provided for @askingForBook.
  ///
  /// In en, this message translates to:
  /// **'Asking {nickname} for the book...'**
  String askingForBook(String nickname);

  /// No description provided for @anotherReader.
  ///
  /// In en, this message translates to:
  /// **'another reader'**
  String get anotherReader;

  /// No description provided for @aReader.
  ///
  /// In en, this message translates to:
  /// **'A reader'**
  String get aReader;

  /// The language toggle on Home: names the other language, in that language.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get switchLanguage;

  /// No description provided for @switchLanguageTooltip.
  ///
  /// In en, this message translates to:
  /// **'Switch to Chinese'**
  String get switchLanguageTooltip;

  /// No description provided for @txtNeedsTitle.
  ///
  /// In en, this message translates to:
  /// **'The book needs a title.'**
  String get txtNeedsTitle;

  /// No description provided for @txtPickAtLeastOne.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one TXT file.'**
  String get txtPickAtLeastOne;

  /// No description provided for @txtNoText.
  ///
  /// In en, this message translates to:
  /// **'These files have no text in them.'**
  String get txtNoText;

  /// No description provided for @cannotReadFile.
  ///
  /// In en, this message translates to:
  /// **'Cannot read {fileName}'**
  String cannotReadFile(String fileName);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
