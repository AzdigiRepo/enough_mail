import 'dart:io';
import 'package:enough_mail/imap/metadata.dart';
import 'package:enough_mail/src/imap/response_parser.dart';
import 'package:event_bus/event_bus.dart';
import 'package:enough_mail/imap/mailbox.dart';
import 'package:enough_mail/mime_message.dart';
import 'package:enough_mail/imap/response.dart';
import 'package:enough_mail/src/imap/capability_parser.dart';
import 'package:enough_mail/src/imap/command.dart';
import 'package:enough_mail/src/imap/all_parsers.dart';
import 'package:enough_mail/src/imap/imap_response.dart';
import 'package:enough_mail/src/imap/imap_response_reader.dart';

import 'events.dart';

/// Describes a capability
class Capability {
  String name;
  Capability(this.name);

  @override
  String toString() {
    return name;
  }
}

/// Keeps information about the remote IMAP server
///
/// Persist this information to improve initialization times.
class ImapServerInfo {
  String host;
  bool isSecure;
  int port;
  String pathSeparator;
  String capabilitiesText;
  List<Capability> capabilities;
}

enum StoreAction { add, remove, replace }

enum StatusFlags { messages, recent, uidNext, uidValidity, unseen }

/// Low-level IMAP library for Dartlang
///
/// Compliant to IMAP4rev1 standard [RFC 3501].
class ImapClient {
  /// Information about the IMAP service
  ImapServerInfo serverInfo;

  /// Allows to listens for events
  ///
  /// If no event bus is specified in the constructor, an aysnchronous bus is used.
  /// Usage:
  /// ```
  /// eventBus.on<ImapExpungeEvent>().listen((event) {
  ///   // All events are of type ImapExpungeEvent (or subtypes of it).
  ///   _log(event.messageSequenceId);
  /// });
  ///
  /// eventBus.on<ImapEvent>().listen((event) {
  ///   // All events are of type ImapEvent (or subtypes of it).
  ///   _log(event.eventType);
  /// });
  /// ```
  EventBus eventBus;

  bool _isSocketClosingExpected = false;

  /// Checks if a user is currently signed in.
  bool get isLoggedIn => _isLoggedIn;

  /// Checks if a user is currently not signed in.
  bool get isNotLoggedIn => !_isLoggedIn;

  bool _isLoggedIn = false;
  Socket _socket;
  int _lastUsedCommandId = 0;
  CommandTask _currentCommandTask;
  final Map<String, CommandTask> _tasks = <String, CommandTask>{};
  Mailbox _selectedMailbox;
  bool _isLogEnabled;
  ImapResponseReader _imapResponseReader;

  bool _isInIdleMode = false;

  /// Creates a new instance with the optional [bus] event bus.
  ///
  /// Compare [eventBus] for more information.
  ImapClient({EventBus bus, bool isLogEnabled = false}) {
    eventBus ??= EventBus();
    _isLogEnabled = isLogEnabled ?? false;
    _imapResponseReader = ImapResponseReader(onServerResponse);
  }

  /// Connects to the specified server.
  ///
  /// Specify [isSecure] if you do not want to connect to a secure service.
  Future<Socket> connectToServer(String host, int port,
      {bool isSecure = true}) async {
    serverInfo = ImapServerInfo();
    serverInfo.host = host;
    serverInfo.port = port;
    serverInfo.isSecure = isSecure;
    _log(
        'Connecting to $host:$port ${isSecure ? '' : 'NOT'} using a secure socket...');

    var socket = isSecure
        ? await SecureSocket.connect(host, port)
        : await Socket.connect(host, port);
    connect(socket);
    return socket;
  }

  /// Starts to liste on [socket].
  ///
  /// This is mainly useful for testing purposes, ensure to set [serverInfo] manually in this  case.
  void connect(Socket socket) {
    socket.listen(_imapResponseReader.onData, onDone: () {
      _isLoggedIn = false;
      _log('Done, connection closed');
      if (!_isSocketClosingExpected) {
        eventBus.fire(ImapConnectionLostEvent());
      }
    }, onError: (error) {
      _isLoggedIn = false;
      _log('Error: $error');
      if (!_isSocketClosingExpected) {
        eventBus.fire(ImapConnectionLostEvent());
      }
    });
    _isSocketClosingExpected = false;
    _socket = socket;
  }

  /// Logs the specified user in with the given [name] and [passowrd].
  Future<Response<List<Capability>>> login(String name, String password) async {
    var cmd = Command('LOGIN $name $password');
    cmd.logText = 'LOGIN $name (password scrambled)';
    var parser = CapabilityParser(serverInfo);
    var response = await sendCommand<List<Capability>>(cmd, parser);
    _isLoggedIn = response.isOkStatus;
    return response;
  }

  /// Logs the current user out.
  Future<Response<String>> logout() async {
    var cmd = Command('LOGOUT');
    var response = await sendCommand<String>(cmd, LogoutParser());
    _isLoggedIn = false;
    return response;
  }

  /// Upgrades the current insure connection to SSL.
  ///
  /// Opportunistic TLS (Transport Layer Security) refers to extensions
  /// in plain text communication protocols, which offer a way to upgrade a plain text connection
  /// to an encrypted (TLS or SSL) connection instead of using a separate port for encrypted communication.
  Future<Response<GenericImapResult>> startTls() async {
    var cmd = Command('STARTTLS');
    var response = await sendCommand<GenericImapResult>(cmd, GenericParser());
    if (response.isOkStatus) {
      _log('STARTTL: upgrading socket to secure one...');
      var secureSocket = await SecureSocket.secure(_socket);
      if (secureSocket != null) {
        _log('STARTTL: now using secure connection.');
        _isSocketClosingExpected = true;
        await _socket.close();
        await _socket.destroy();
        _isSocketClosingExpected = false;
        connect(secureSocket);
      }
    }
    return response;
  }

  /// Copies the specified message(s) with the specified [messageSequenceId] and the optional [lastMessageSequenceId] from the currently selected mailbox to the target mailbox.
  /// You can either specify the [targetMailbox] or the [targetMailboxPath], if none is given, the messages will be copied to the currently selected mailbox.
  /// Compare [selectMailbox()], [selectMailboxByPath()] or [selectInbox()] for selecting a mailbox first.
  Future<Response<GenericImapResult>> copy(int messageSequenceId,
      {int lastMessageSequenceId,
      Mailbox targetMailbox,
      String targetMailboxPath}) {
    if (_selectedMailbox == null) {
      throw StateError('No mailbox selected.');
    }
    var buffer = StringBuffer()..write('COPY ')..write(messageSequenceId);
    if (lastMessageSequenceId != null && lastMessageSequenceId != -1) {
      buffer..write(':')..write(lastMessageSequenceId);
    }
    var path =
        targetMailbox?.path ?? targetMailboxPath ?? _selectedMailbox.path;
    buffer..write(' ')..write(path);
    var cmd = Command(buffer.toString());
    return sendCommand<GenericImapResult>(cmd, GenericParser());
  }

  /// Updates the [flags] of the message(s) with the specified [messageSequenceId] and the optional [lastMessageSequenceId] from the currently selected mailbox.
  /// Set [silent] to true, if the updated flags should not be returned.
  /// Specify if flags should be replaced, added or removed with the [action] parameter, this defaults to adding flags.
  /// Compare [selectMailbox()], [selectMailboxByPath()] or [selectInbox()] for selecting a mailbox first.
  /// Compare the methods [markSeen()], [markFlagged()], etc for typical store operations.
  Future<Response<List<MimeMessage>>> store(
      int messageSequenceId, List<String> flags,
      {StoreAction action, int lastMessageSequenceId, bool silent}) {
    if (_selectedMailbox == null) {
      throw StateError('No mailbox selected.');
    }
    action ??= StoreAction.add;
    silent ??= false;
    var buffer = StringBuffer()..write('STORE ')..write(messageSequenceId);
    if (lastMessageSequenceId != null && lastMessageSequenceId != -1) {
      buffer..write(':')..write(lastMessageSequenceId);
    }
    switch (action) {
      case StoreAction.add:
        buffer.write(' +FLAGS');
        break;
      case StoreAction.remove:
        buffer.write(' -FLAGS');
        break;
      default:
        buffer.write(' FLAGS');
    }
    if (silent) {
      buffer.write('.SILENT');
    }
    buffer.write(' (');
    var addSpace = false;
    for (var flag in flags) {
      if (addSpace) {
        buffer.write(' ');
      }
      buffer.write(flag);
      addSpace = true;
    }
    buffer.write(')');
    var cmd = Command(buffer.toString());
    var parser = FetchParser();
    return sendCommand<List<MimeMessage>>(cmd, parser);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as seen/read.
  /// Specify the [lastMessageSequenceId] in case you want to change the seen state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markSeen(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Seen'],
        lastMessageSequenceId: lastMessageSequenceId, silent: silent);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as unseen/unread.
  /// Specify the [lastMessageSequenceId] in case you want to change the seen state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markUnseen(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Seen'],
        action: StoreAction.remove,
        lastMessageSequenceId: lastMessageSequenceId,
        silent: silent);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as flagged.
  /// Specify the [lastMessageSequenceId] in case you want to change the flagged state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markFlagged(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Flagged'],
        lastMessageSequenceId: lastMessageSequenceId, silent: silent);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as unflagged.
  /// Specify the [lastMessageSequenceId] in case you want to change the flagged state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markUnflagged(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Flagged'],
        action: StoreAction.remove,
        lastMessageSequenceId: lastMessageSequenceId,
        silent: silent);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as deleted.
  /// Specify the [lastMessageSequenceId] in case you want to change the deleted state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markDeleted(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Deleted'],
        lastMessageSequenceId: lastMessageSequenceId, silent: silent);
  }

  /// Convenience method for marking the with the specified [messageSequenceId] as not deleted.
  /// Specify the [lastMessageSequenceId] in case you want to change the deleted state for a range of message.
  /// Set [silent] to true in case the updated flags are of no interest.
  /// Compare the [store()] method in case you need more control or want to change several flags.
  Future<Response<List<MimeMessage>>> markUndeleted(int messageSequenceId,
      {int lastMessageSequenceId, bool silent}) {
    return store(messageSequenceId, [r'\Deleted'],
        action: StoreAction.remove,
        lastMessageSequenceId: lastMessageSequenceId,
        silent: silent);
  }

  /// Trigger a noop (no operation).
  ///
  /// A noop can update the info about the currently selected mailbox and can be used as a keep alive.
  /// Also compare [idleStart] for starting the IMAP IDLE mode on compatible servers.
  Future<Response<Mailbox>> noop() {
    var cmd = Command('NOOP');
    return sendCommand<Mailbox>(cmd, NoopParser(eventBus, _selectedMailbox));
  }

  /// lists all mailboxes in the given [path].
  ///
  /// The [path] default to "", meaning the currently selected mailbox, if there is none selected, then the root is used.
  /// When [recursive] is true, then all submailboxes are also listed.
  /// The LIST command will set the [serverInfo.pathSeparator] as a side-effect
  Future<Response<List<Mailbox>>> listMailboxes(
      {String path = '""', bool recursive = false}) {
    return listMailboxesByReferenceAndName(
        path, (recursive ? '*' : '%')); // list all folders in that path
  }

  /// lists all mailboxes in the path [referenceName] that match the given [mailboxName] that can contain wildcards.
  ///
  /// The LIST command will set the [serverInfo.pathSeparator] as a side-effect
  Future<Response<List<Mailbox>>> listMailboxesByReferenceAndName(
      String referenceName, String mailboxName) {
    var cmd = Command('LIST $referenceName $mailboxName');
    var parser = ListParser(serverInfo);
    return sendCommand<List<Mailbox>>(cmd, parser);
  }

  /// Lists all subscribed mailboxes
  ///
  /// The [path] default to "", meaning the currently selected mailbox, if there is none selected, then the root is used.
  /// When [recursive] is true, then all submailboxes are also listed.
  /// The LIST command will set the [serverInfo.pathSeparator] as a side-effect
  Future<Response<List<Mailbox>>> listSubscribedMailboxes(
      {String path = '""', bool recursive = false}) {
    //Command cmd = Command("LIST \"INBOX/\" %");
    var cmd = Command('LSUB $path ' +
        (recursive ? '*' : '%')); // list all folders in that path
    var parser = ListParser(serverInfo, isLsubParser: true);
    return sendCommand<List<Mailbox>>(cmd, parser);
  }

  /// Selects the specified mailbox.
  ///
  /// This allows future search and fetch calls.
  /// [box] the mailbox that should be selected.
  Future<Response<Mailbox>> selectMailbox(Mailbox box) {
    var cmd = Command('SELECT ' + box.path);
    var parser = SelectParser(box);
    _selectedMailbox = box;
    return sendCommand<Mailbox>(cmd, parser);
  }

  /// Selects the specified mailbox.
  ///
  /// This allows future search and fetch calls.
  /// [path] the path or name of the mailbox that should be selected.
  Future<Response<Mailbox>> selectMailboxByPath(String path) async {
    if (serverInfo?.pathSeparator == null) {
      await listMailboxes();
    }
    var nameSplitIndex = path.lastIndexOf(serverInfo.pathSeparator);
    var name = nameSplitIndex == -1 ? path : path.substring(nameSplitIndex + 1);
    var box = Mailbox()
      ..path = path
      ..name = name;
    return selectMailbox(box);
  }

  /// Selects the inbox.
  ///
  /// This allows future search and fetch calls.
  /// [path] the path or name of the mailbox that should be selected.
  Future<Response<Mailbox>> selectInbox() {
    return selectMailboxByPath('INBOX');
  }

  /// Closes the currently selected mailbox.
  ///
  /// Compare [selectMailbox]
  Future<Response> closeMailbox() {
    var cmd = Command('CLOSE');
    _selectedMailbox = null;
    return sendCommand(cmd, null);
  }

  /// Searches messages by the given criteria
  ///
  /// [searchCriteria] the criteria like 'UNSEEN' or 'RECENT'
  Future<Response<List<int>>> searchMessages(
      [String searchCriteria = 'UNSEEN']) {
    var cmd = Command('SEARCH $searchCriteria');
    var parser = SearchParser();
    return sendCommand<List<int>>(cmd, parser);
  }

  /// Fetches messages by the given definition.
  ///
  /// [messageSequenceId] the message sequence ID of the desired message
  /// [fetchContentDefinition] the definition of what should be fetched from the message, e.g. 'BODY[]' or 'ENVELOPE', etc
  Future<Response<List<MimeMessage>>> fetchMessage(
      int messageSequenceId, String fetchContentDefinition) {
    return fetchMessages(messageSequenceId, null, fetchContentDefinition);
  }

  /// Fetches messages by the given definition.
  ///
  /// [lowerMessageSequenceId] the message sequence ID from which messages should be fetched
  /// [upperMessageSequenceId] the message sequence ID until which messages should be fetched
  /// [fetchContentDefinition] the definition of what should be fetched from the message, e.g. 'BODY[]' or 'ENVELOPE', etc
  Future<Response<List<MimeMessage>>> fetchMessages(int lowerMessageSequenceId,
      int upperMessageSequenceId, String fetchContentDefinition) {
    var cmdText = StringBuffer();
    cmdText.write('FETCH ');
    cmdText.write(lowerMessageSequenceId);
    if (upperMessageSequenceId != null &&
        upperMessageSequenceId != -1 &&
        upperMessageSequenceId != lowerMessageSequenceId) {
      cmdText.write(':');
      cmdText.write(upperMessageSequenceId);
    }
    cmdText.write(' ');
    cmdText.write(fetchContentDefinition);
    var cmd = Command(cmdText.toString());
    var parser = FetchParser();
    return sendCommand<List<MimeMessage>>(cmd, parser);
  }

  /// Fetches messages by the specified criteria.
  ///
  /// This call is more flexible than [fetchMessages].
  /// [fetchIdsAndCriteria] the requested message IDs and specification of the requested elements, e.g. '1:* (ENVELOPE)'.
  Future<Response<List<MimeMessage>>> fetchMessagesByCriteria(
      String fetchIdsAndCriteria) {
    var cmd = Command('FETCH $fetchIdsAndCriteria');
    var parser = FetchParser();
    return sendCommand<List<MimeMessage>>(cmd, parser);
  }

  /// Fetches the specified number of recent messages by the specified criteria.
  ///
  /// [messageCount] optional number of messages that should be fetched, defaults to 30
  /// [criteria] optional fetch criterria of the requested elements, e.g. '(ENVELOPE BODY.PEEK[])'. Defaults to 'BODY[]'.
  Future<Response<List<MimeMessage>>> fetchRecentMessages(
      {int messageCount = 30, String criteria = 'BODY[]'}) {
    var box = _selectedMailbox;
    if (box == null) {
      throw StateError('No mailbox selected - call select() first.');
    }
    var upperMessageSequenceId = box.messagesExists;
    var lowerMessageSequenceId = upperMessageSequenceId - messageCount;
    return fetchMessages(
        lowerMessageSequenceId, upperMessageSequenceId, criteria);
  }

  /// Retrieves the specified meta data entry.
  ///
  /// [entry] defines the path of the meta data
  /// Optionally specify [mailboxName], the [maxSize] in bytes or the [depth].
  ///
  /// Compare https://tools.ietf.org/html/rfc5464 for details.
  /// Note that errata of the RFC exist.
  Future<Response<List<MetaDataEntry>>> getMetaData(String entry,
      {String mailboxName, int maxSize, MetaDataDepth depth}) {
    var cmd = 'GETMETADATA ';
    if (maxSize != null || depth != null) {
      cmd += '(';
    }
    if (maxSize != null) {
      cmd += 'MAXSIZE $maxSize';
    }
    if (depth != null) {
      if (maxSize != null) {
        cmd += ' ';
      }
      cmd += 'DEPTH ';
      switch (depth) {
        case MetaDataDepth.none:
          cmd += '0';
          break;
        case MetaDataDepth.directChildren:
          cmd += '1';
          break;
        case MetaDataDepth.allChildren:
          cmd += 'infinity';
          break;
      }
    }
    if (maxSize != null || depth != null) {
      cmd += ') ';
    }
    cmd += '"${mailboxName ?? ''}" ($entry)';
    var parser = MetaDataParser();
    return sendCommand<List<MetaDataEntry>>(Command(cmd), parser);
  }

  /// Checks if the specified value can be safely send to the IMAP server just in double-quotes.
  bool _isSafeForQuotedTransmission(String value) {
    return value.length < 80 && !value.contains('"') && !value.contains('\n');
  }

  /// Saves the specified meta data entry.
  ///
  /// Set [MetaDataEntry.value] to null to delete the specified meta data entry
  /// Compare https://tools.ietf.org/html/rfc5464 for details.
  Future<Response<Mailbox>> setMetaData(MetaDataEntry entry) {
    var valueText = entry.valueText;
    Command cmd;
    if (entry.value == null || _isSafeForQuotedTransmission(valueText)) {
      var cmdText =
          'SETMETADATA "${entry.mailboxName ?? ''}" (${entry.entry} ${entry.value == null ? 'NIL' : '"' + valueText + '"'})';
      cmd = Command(cmdText);
    } else {
      // this is a complex command that requires continuation responses
      var parts = <String>[
        'SETMETADATA "${entry.mailboxName ?? ''}" (${entry.entry} {${entry.value.length}}',
        entry.valueText + ')'
      ];
      cmd = Command.withContinuation(parts);
    }
    var parser = NoopParser(eventBus, _selectedMailbox);
    return sendCommand<Mailbox>(cmd, parser);
  }

  /// Saves the all given meta data entries.
  /// Note that each [MetaDataEntry.mailboxName] is expected to be the same.
  ///
  /// Set [MetaDataEntry.value] to null to delete the specified meta data entry
  /// Compare https://tools.ietf.org/html/rfc5464 for details.
  Future<Response<Mailbox>> setMetaDataEntries(List<MetaDataEntry> entries) {
    var parts = <String>[];
    var cmd = StringBuffer();
    cmd.write('SETMETADATA ');
    var entry = entries.first;
    cmd.write('"${entry.mailboxName ?? ''}" (');
    for (entry in entries) {
      cmd.write(' ');
      cmd.write(entry.entry);
      cmd.write(' ');
      if (entry.value == null) {
        cmd.write('NIL');
      } else if (_isSafeForQuotedTransmission(entry.valueText)) {
        cmd.write('"${entry.valueText}"');
      } else {
        cmd.write('{${entry.value.length}}');
        parts.add(cmd.toString());
        cmd = StringBuffer();
        cmd.write(entry.valueText);
      }
    }
    cmd.write(')');
    parts.add(cmd.toString());
    var parser = NoopParser(eventBus, _selectedMailbox);
    Command command;
    if (parts.length == 1) {
      command = Command(parts.first);
    } else {
      command = Command.withContinuation(parts);
    }
    return sendCommand<Mailbox>(command, parser);
  }

  /// Examines the [box] without selecting it.
  ///
  /// Also compare: statusMailbox(Mailbox, StatusFlags)
  /// The EXAMINE command is identical to SELECT and returns the same
  /// output; however, the selected mailbox is identified as read-only.
  /// No changes to the permanent state of the mailbox, including
  /// per-user state, are permitted; in particular, EXAMINE MUST NOT
  /// cause messages to lose the \Recent flag.
  Future<Response<Mailbox>> examineMailbox(Mailbox box) {
    var cmd = Command('EXAMINE ${box.path}');
    var parser = SelectParser(box);
    return sendCommand<Mailbox>(cmd, parser);
  }

  /// Checks the status of the currently not selected [box].
  ///
  ///  The STATUS command requests the status of the indicated mailbox.
  ///  It does not change the currently selected mailbox, nor does it
  ///  affect the state of any messages in the queried mailbox (in
  ///  particular, STATUS MUST NOT cause messages to lose the \Recent
  ///  flag).
  ///
  ///  The STATUS command provides an alternative to opening a second
  ///  IMAP4rev1 connection and doing an EXAMINE command on a mailbox to
  ///  query that mailbox's status without deselecting the current
  ///  mailbox in the first IMAP4rev1 connection.
  Future<Response<Mailbox>> statusMailbox(
      Mailbox box, List<StatusFlags> flags) {
    var flagsStr = '(';
    var addSpace = false;
    for (var flag in flags) {
      if (addSpace) {
        flagsStr += ' ';
      }
      switch (flag) {
        case StatusFlags.messages:
          flagsStr += 'MESSAGES';
          addSpace = true;
          break;
        case StatusFlags.recent:
          flagsStr += 'RECENT';
          addSpace = true;
          break;
        case StatusFlags.uidNext:
          flagsStr += 'UIDNEXT';
          addSpace = true;
          break;
        case StatusFlags.uidValidity:
          flagsStr += 'UIDVALIDITY';
          addSpace = true;
          break;
        case StatusFlags.unseen:
          flagsStr += 'UNSEEN';
          addSpace = true;
          break;
      }
    }
    flagsStr += ')';
    var cmd = Command('STATUS ${box.path} $flagsStr');
    var parser = StatusParser(box);
    return sendCommand<Mailbox>(cmd, parser);
  }

  /// Creates the specified mailbox
  ///
  /// Spefify the name with [path]
  Future<Response<Mailbox>> createMailbox(String path) async {
    var cmd = Command('CREATE $path');
    var response = await sendCommand<Mailbox>(cmd, null);
    if (response.isOkStatus) {
      var mailboxesResponse = await listMailboxes(path: path);
      if (mailboxesResponse.isOkStatus &&
          mailboxesResponse.result != null &&
          mailboxesResponse.result.isNotEmpty) {
        response.result = mailboxesResponse.result[0];
        return response;
      }
    }
    return response;
  }

  /// Removes the specified mailbox
  ///
  /// [box] the mailbox to be deleted
  Future<Response<Mailbox>> deleteMailbox(Mailbox box) {
    var cmd = Command('DELETE ${box.path}');
    return sendCommand<Mailbox>(cmd, null);
  }

  /// Renames the specified mailbox
  ///
  /// [box] the mailbox that should be renamed
  /// [newName] the desired future name of the mailbox
  Future<Response<Mailbox>> renameMailbox(Mailbox box, String newName) async {
    var cmd = Command('RENAME ${box.path} $newName');
    var response = await sendCommand<Mailbox>(cmd, null);
    if (response.isOkStatus) {
      if (box.name == 'INBOX') {
        /* Renaming INBOX is permitted, and has special behavior.  It moves
        all messages in INBOX to a new mailbox with the given name,
        leaving INBOX empty.  If the server implementation supports
        inferior hierarchical names of INBOX, these are unaffected by a
        rename of INBOX.
        */
        // question: do we need to create a new mailbox and return that one instead?
      }
      box.name = newName;
    }
    return response;
  }

  /// Subscribes the specified mailbox.
  ///
  /// The mailbox is listed in future LSUB commands, compare [listSubscribedMailboxes].
  /// [box] the mailbox that is subscribed
  Future<Response<Mailbox>> subscribeMailbox(Mailbox box) {
    var cmd = Command('SUBSCRIBE ${box.path}');
    return sendCommand<Mailbox>(cmd, null);
  }

  /// Unsubscribes the specified mailbox.
  ///
  /// [box] the mailbox that is unsubscribed
  Future<Response<Mailbox>> unsubscribeMailbox(Mailbox box) {
    var cmd = Command('UNSUBSCRIBE ${box.path}');
    return sendCommand<Mailbox>(cmd, null);
  }

  /// Switches to IDLE mode.
  /// Requires a mailbox to be selected.
  Future<Response<Mailbox>> idleStart() {
    if (_selectedMailbox == null) {
      print('idle: no mailbox selected');
    }
    _isInIdleMode = true;
    var cmd = Command('IDLE');
    return sendCommand<Mailbox>(cmd, NoopParser(eventBus, _selectedMailbox));
  }

  /// Stops the IDLE mode,
  /// for example after receiving information about a new message.
  /// Requires a mailbox to be selected.
  void idleDone() {
    if (_isInIdleMode) {
      _isInIdleMode = false;
      write('DONE');
    }
  }

  String nextId() {
    var id = _lastUsedCommandId++;
    return 'a$id';
  }

  Future<Response<T>> sendCommand<T>(
      Command command, ResponseParser<T> parser) {
    var task = CommandTask<T>(command, nextId(), parser);
    _tasks[task.id] = task;
    writeTask(task);
    return task.completer.future;
  }

  void writeTask(CommandTask task) {
    _currentCommandTask = task;
    _log('C: $task');
    _socket?.write(task.toImapRequest() + '\r\n');
  }

  void write(String commandText) {
    _log('C: $commandText');
    _socket?.write(commandText + '\r\n');
  }

  void onServerResponse(ImapResponse imapResponse) {
    _log('S: $imapResponse');
    var line = imapResponse.parseText;
    //var log = imapResponse.toString().replaceAll("\r\n", "<RT><LF>\n");
    //_log("S: $log");

    //_log("subline: " + line);
    if (line.startsWith('* ')) {
      // this is an untagged response and can be anything
      imapResponse.parseText = line.substring('* '.length);
      onUntaggedResponse(imapResponse);
    } else if (line.startsWith('+ ')) {
      imapResponse.parseText = line.substring('+ '.length);
      onContinuationResponse(imapResponse);
    } else {
      onCommandResult(imapResponse);
    }
  }

  void onCommandResult(ImapResponse imapResponse) {
    var line = imapResponse.parseText;
    var spaceIndex = line.indexOf(' ');
    if (spaceIndex != -1) {
      var commandId = line.substring(0, spaceIndex);
      var task = _tasks[commandId];
      if (task != null) {
        if (task == _currentCommandTask) {
          _currentCommandTask = null;
        }
        imapResponse.parseText = line.substring(spaceIndex + 1);
        var response = task.parse(imapResponse);
        task.completer.complete(response);
      } else {
        _log('ERROR: no task found for command [$commandId]');
      }
    } else {
      _log('unexpected SERVER response: [$imapResponse]');
    }
  }

  void onUntaggedResponse(ImapResponse imapResponse) {
    var task = _currentCommandTask;
    if (task == null || !task.parseUntaggedResponse(imapResponse)) {
      _log('untagged not handled: [$imapResponse] by task $task');
    }
  }

  void onContinuationResponse(ImapResponse imapResponse) {
    var cmd = _currentCommandTask?.command;
    if (cmd != null) {
      var response = cmd.getContinuationResponse(imapResponse);
      if (response != null) {
        write(response);
        return;
      }
    }
    if (!_isInIdleMode) {
      _log('continuation not handled: [$imapResponse]');
    }
  }

  void writeCommand(String command) {
    var id = _lastUsedCommandId++;
    _socket?.writeln('$id $command');
  }

  Future<dynamic> close() {
    _log('Closing socket for host ${serverInfo.host}');
    _isSocketClosingExpected = true;
    return _socket?.close();
  }

  void _log(String text) {
    if (_isLogEnabled) {
      print(text);
    }
  }
}
