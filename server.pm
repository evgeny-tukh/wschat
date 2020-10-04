#!/usr/bin/env perl

use strict;
use warnings;

use Net::WebSocket::Server;
use DBI;
use DBD::mysql;
use threads ('yield', 'stack_size' => 64*4096, 'exit' => 'threads_only', 'stringify');
use JSON;

my %config = do 'config.pl';

my %dbConnections = ();

my %chats = ();

print "Waiting for incoming connections...\n";

Net::WebSocket::Server->new(
    listen => $config {port},
    on_connect => \&processConnection,
    #on_connect => sub {
    #    my ($serv, $dbConn) = @_;
    #    $dbConn->on(
    #        utf8 => sub {
    #            my ($dbConn, $msg) = @_;
    #            $dbConn->send_utf8("hi there: $msg");
    #        },
    #    );
    #},
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

        if ($msgObject->{action} eq 'start') {
            $connection->{dbConn} = connectToDb ();
            $connection->{chatID} = startChat ($connection, $msgObject->{from}, $msgObject->{to});

            print "Chat ", $connection->{chatID}, " started\n";
        } elsif ($msgObject->{action} eq 'send') {
            print "From:\t", $msgObject->{from}, "\n";
            print "To:\t", $msgObject->{to}, "\n";
            print "Text:\t", $msgObject->{msg}, "\n";
        }
    }
}

# called when connection is ended
sub onDisconnect {
    my ($connection, $code, $reason) = @_;

    $connection->{dbConn}->disconnect if ($connection->{dbConn});
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

    if (defined ($chats {$key})) {
        $id = $chats {$key}{id};
    } else {
        $id = findArchiveChat ($dbConn, \@participants, $key);

        $chats {$key} = ();

        $chats {$key}{id} = $id;
        $chats {$key}{participants} = @participants;
        $chats {$key}{initiator} = $newTalker;
        $chats {$key}{sessions} = ();
        $chats {$key}{sessions}{$newTalker} = $connection;
    }

    return $id;
}

# dies with appropriate text
sub dbShowError {
    die "failed: ".$_[0]->errstr;
}
