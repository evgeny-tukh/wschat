#!/usr/bin/env perl

use strict;
use warnings;

use Net::WebSocket::Server;
use DBI;
use DBD::mysql;
use threads ('yield', 'stack_size' => 64*4096, 'exit' => 'threads_only', 'stringify');
use JSON;
use Data::Dumper;

use constant {
    TALKER_JOINED => 'joined',
    TALKER_LEFT => 'left',
    YOU_JOINED => 'you-joined',
    YOU_LEFT => 'you-left',

    ACTION_START => 'start',
    ACTION_SEND => 'send',
    ACTION_RESPOND => 'respond',
    ACTION_NOTIFY => 'notify',
    ACTION_HISTORY => 'history',

    MSG_SENT => 'msg',
};

my %config = do 'config.pl';

my %dbConnections = ();

my %chats = ();

print "Waiting for incoming connections...\n";

Net::WebSocket::Server->new (
    listen => $config {port},
    on_connect => \&processConnection,
)->start;

# connection process procedure
sub processConnection {
    my ($server, $connection) = @_;

    print "Connection established.\n";

    $connection->on (
        ready => \&onConnectionReady,
        utf8 => \&onMessage,
        disconnect => \&onDisconnect,
    );
}

# called when handshake is ok and connection is ready
sub onConnectionReady {
    my ($connection) = @_;
}

# called when message has been received
sub onMessage {
    my ($connection, $message) = @_;

    if ($message eq "echo") {
        print "Echo received\n";
    } else {
        my $msgObject = decode_json ($message);

        if ($msgObject->{action} eq ACTION_START) {
            $connection->{dbConn} = connectToDb ();
            $connection->{chatID} = startChat ($connection, $msgObject->{from}, $msgObject->{to});

            print "Chat ", $connection->{chatID}, " started\n";
        } elsif ($msgObject->{action} eq ACTION_SEND) {
            # notify other participants about the message sent
            notifyParticipants ($chats {$connection->{chatKey}}, MSG_SENT, $msgObject);

            # add message to the database
            saveMessage ($connection->{dbConn}, $connection->{chatID}, $msgObject);

            print "From:\t", $msgObject->{from}, "\n";
            print "To:\t", $msgObject->{to}, "\n";
            print "Text:\t", $msgObject->{msg}, "\n";
        }
    }
}

# called when connection is ended
sub onDisconnect {
    my ($connection, $code, $reason) = @_;

    # notify other participants that new talker joined the chat
    notifyParticipants ($chats {$connection->{chatKey}}, TALKER_LEFT, $connection->{nick});

    # remove session from the chat
    delete $connection->{sessions}{$connection->{nick}} if defined ($connection->{nick}) && defined ($connection->{sessions}{$connection->{nick}});

    # delete chat if there is nobody
    delete $chats {$connection->{chatKey}} if (scalar (keys (%chats)) == 0);

    # disconnect the database
    $connection->{dbConn}->disconnect if ($connection->{dbConn});

    print "Chat '", $connection->{chatKey}, "' disconnected\n";
}

# establish new connection to the database
sub connectToDb {
    # MySQL configuration
    my %dbConfig = do 'dbconfig.pl';
    my $database = $dbConfig {database};
    my $databaseHost = $dbConfig {databaseHost};
    my $databasePort = $dbConfig {databasePort};
    my $databaseUser = $dbConfig {databaseUser};
    my $databasePass = $dbConfig {databasePass};

    print "Connecting to database $database\n";

    my $dsn = "DBI:mysql:database=$database;host=$databaseHost;port=$databasePort";
    my $dbConn = DBI->connect ($dsn, $databaseUser, $databasePass) or die "DB connection failed";

    return $dbConn;
}

# ensure that all talkers do exist, create new ones if needed
sub ensureTalkersExist {
    my $dbConn = $_ [0];
    my $talkersRef = $_ [1];

    my $statement = $dbConn->prepare ("insert ignore into talkers(nick,name) values(?,?)");

    for my $talker (@$talkersRef) {
        $statement->execute ($talker, $talker);
    }

    $statement->finish;
}

# create unique conversation key by talker list
sub createChatKey {
    my $dbConn = $_ [0];
    my $talkersRef = $_ [1];
    my @talkerIDs = ();
    my $statement = $dbConn->prepare ("select id from talkers where nick in ('".join ("','", @$talkersRef)."')") or dbShowError ($dbConn);
    my $row;

    $statement->execute or dbShowError ($dbConn);

    do {
        $row = $statement->fetchrow_hashref;
        
        push (@talkerIDs, $row->{id} + 0) if (defined ($row));
    } while (defined ($row));

    $statement->finish;
    
    return join (',', sort (@talkerIDs));
}

# find the existing chat in the database
# if the chat does not exist we create new one
sub findArchiveChat {
    my $dbConn = $_ [0];
    my $participants = $_ [1];
    my $key = $_ [2];
    my $id;
    my $row;
    my $statement;

    # make sure that char exists, if it does not, we create new one
    $statement = $dbConn->prepare ("select id from conversations where `key`=?") or dbShowError ($dbConn);

    $statement->execute ($key) or dbShowError ($dbConn);

    $row = $statement->fetchrow_hashref;

    $id = $row->{id} + 0 if (defined ($row));

    $statement->finish;

    if (!defined ($id)) {
        # chat does not exist yet, create new one
        my $chatName = join (',', @$participants);

        $statement = $dbConn->prepare ("insert into conversations(`name`,`key`) values ('$chatName', '$key')");
        
        $statement->execute or dbShowError ($dbConn);

        $id = $statement->{mysql_insertid};

        $statement->finish;
    }

    return $id;
}

# notify participants about some events
sub notifyParticipants {
    my ($chat, $event, $arg) = @_;
    my $sessions = $chat->{sessions};

    if ($event eq TALKER_JOINED || $event eq TALKER_LEFT) {
        while (my ($nick, $session) = each (%$sessions)) {
            if ($arg ne $nick) {
                my %parcel = (
                    action => ACTION_NOTIFY,
                    event => $event,
                    arg => $arg,
                );

                $session->send_utf8 (encode_json (\%parcel));
            }
        }
    } elsif ($event eq MSG_SENT) {
        while (my ($nick, $session) = each (%$sessions)) {
            $session->send_utf8 (encode_json ($arg));
        }
    }
}

# initiate the conversation
sub startChat {
    my $connection = $_ [0];
    my @participants = @_ [1..$#_];
    my $newTalker = $_ [1];
    my $dbConn = $connection->{dbConn};
    my $id;
    my $key;

    # make sure that all talkers exist, if some do not, we create them
    ensureTalkersExist ($dbConn, \@participants);

    # generate the unique chat index
    $key = createChatKey ($dbConn, \@participants);

    $connection->{chatKey} = $key;
    $connection->{nick} = $newTalker;

    my $chat = $chats {$key};

    if (defined ($chat)) {
        $id = $chat->{id};

        # add a new connection to the chat
        $chat->{sessions}{$newTalker} = $connection;

        # notify other participants that new talker joined the chat
        notifyParticipants ($chat, TALKER_JOINED, $newTalker);

        # notify new talker that he joined the conversation
        notifyParticipants ($chat, YOU_JOINED, $newTalker);
    } else {
        $id = findArchiveChat ($dbConn, \@participants, $key);

        $chats {$key} = ();

        $chats {$key}{id} = $id;
        $chats {$key}{participants} = @participants;
        $chats {$key}{initiator} = $newTalker;
        $chats {$key}{sessions} = ();
        $chats {$key}{sessions}{$newTalker} = $connection;
    }

    # load and send the char history
    getAndSendChatHistory ($connection);

    return $id;
}

# dies with appropriate text
sub dbShowError {
    die "failed: ".$_[0]->errstr;
}

# get talker ID by nickname
sub getTalkerID {
    my ($dbConn, $nick) = @_;
    my $talkerID;

    # look for the talker
    my $statement = $dbConn->prepare ("select id from talkers where nick=?");

    $statement->execute ($nick) or dbShowError ($dbConn);

    my $row = $statement->fetchrow_hashref;

    $statement->finish;

    $talkerID = ($row->{id} + 0) if (defined ($row));

    return $talkerID;
}

# save the message to the database
sub saveMessage {
    my ($dbConn, $chatID, $msgObject) = @_;

    # look for the talker
    my $talkerID = getTalkerID ($dbConn, $msgObject->{from});

    if (defined ($talkerID)) {
        my $statement = $dbConn->prepare ("insert into messages(talker,text,conversation) values(?,?,?)");

        $statement->execute ($talkerID, $msgObject->{msg}, $chatID);
        $statement->finish;
    }
}

# load messages of the certain chat
sub loadMessages {
    my ($dbConn, $chatKey, $messages) = @_;

    my %participants = ();
    my $statement = $dbConn->prepare ("select id from conversations where `key`=?") or dbShowError ($dbConn);
    my $row;
    my $chatID;

    $statement->execute ($chatKey);

    $row = $statement->fetchrow_hashref;

    if (defined ($row)) {
        $chatID = $row->{id} + 0;
    } else {
        return;
    }

    $statement = $dbConn->prepare ("select * from talkers where id in ($chatKey)");

    $statement->execute;

    do {
        $row = $statement->fetchrow_hashref;

        if (defined ($row)) {
            $participants {$row->{id} + 0} = $row->{nick};
        }
    } while (defined ($row));

    $statement->finish;
    $statement->execute ();

    $statement = $dbConn->prepare ("select * from messages where conversation=? order by id");

    $statement->execute ($chatID);

    do {
        $row = $statement->fetchrow_hashref;

        if (defined ($row)) {
            my %item = (
                from => $participants {$row->{talker}},
                to => undef,
                msg => $row->{text},
                action => 'send',
            );

            push (@$messages, \%item);
        }
    } while (defined ($row));
}

# get a chat history for the recently joined talker and send it to him
sub getAndSendChatHistory {
    my ($connection) = @_;
    my @history = ();

    loadMessages ($connection->{dbConn}, $connection->{chatKey}, \@history);

    my %parcel = (
        action => ACTION_HISTORY,
        history => \@history,
    );

    $connection->send_utf8 (encode_json (\%parcel));
}
