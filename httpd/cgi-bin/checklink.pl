#!/usr/bin/perl -wT
#
# W3C Link Checker
# by Hugo Haas <hugo@w3.org>
# (c) 1999-2003 World Wide Web Consortium
# based on Renaud Bruyeron's checklink.pl
#
# $Id: checklink.pl,v 3.6.2.11 2003-06-15 21:41:03 ville Exp $
#
# This program is licensed under the W3C(r) License:
#	http://www.w3.org/Consortium/Legal/copyright-software
#
# The documentation is at:
#	http://www.w3.org/2000/07/checklink
#
# See the CVSweb interface at:
#	http://dev.w3.org/cvsweb/validator/httpd/cgi-bin/checklink.pl
#
# An online version is available at:
#	http://validator.w3.org/checklink
#
# Comments and suggestions should be sent to the www-validator mailing list:
#	www-validator@w3.org (with 'checklink' in the subject)
#	http://lists.w3.org/Archives/Public/www-validator/ (archives)

use strict;

# -----------------------------------------------------------------------------

package W3C::UserAgent;

use LWP::UserAgent      qw();
# @@@ Needs also W3C::CheckLink but can't use() it here.

@W3C::UserAgent::ISA =  qw(LWP::UserAgent);

sub simple_request
{
  my $self = shift;
  my $response = $self->W3C::UserAgent::SUPER::simple_request(@_);
  if (! defined($self->{FirstResponse})) {
    $self->{FirstResponse} = $response->code();
    $self->{FirstMessage} = $response->message();
  }
  return $response;
}

sub redirect_ok
{
  my ($self, $request) = @_;

  if ($self->{Checklink_verbose_progress}) {
    &W3C::CheckLink::hprintf("\n%s %s ", $request->method(), $request->uri());
  }

  # Build a map of redirects
  $self->{Redirects}{$self->{fetching}} = $request->uri();
  $self->{fetching} = $request->uri();

  return ($request->method() eq 'POST') ? 0 : 1;
}

# -----------------------------------------------------------------------------

package W3C::CheckLink;

use vars qw($PROGRAM $AGENT $VERSION $CVS_VERSION $REVISION
            $Have_ReadKey $DocType $Accept $ContentTypes %Cfg);

use Config::General 2.06 qw(); # Need 2.06 for -SplitPolicy
use HTML::Entities       qw();
use HTML::Parser    3.00 qw();
use HTTP::Request        qw();
use HTTP::Response       qw();
use Time::HiRes          qw();
use URI                  qw();
use URI::Escape          qw();
use URI::file            qw();
# @@@ Needs also W3C::UserAgent but can't use() it here.

@W3C::CheckLink::ISA =  qw(HTML::Parser);

BEGIN
{
  # Version info
  $PROGRAM       = 'W3C checklink';
  ($AGENT        = $PROGRAM) =~ s/\s+/-/g;
  ($CVS_VERSION) = q$Revision: 3.6.2.11 $ =~ /(\d+[\d\.]*\.\d+)/;
  $VERSION       = sprintf('%d.%02d', $CVS_VERSION =~ /(\d+)\.(\d+)/);
  $REVISION      = sprintf('version %s (c) 1999-2003 W3C', $CVS_VERSION);

  eval "use Term::ReadKey 2.00 qw(ReadMode)";
  $Have_ReadKey = !$@;

  # Pull in mod_perl modules if applicable.
  if ($ENV{MOD_PERL}) {
    eval "require Apache::compat"; # For mod_perl 2
    require Apache;
  }

  $DocType = '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">';

  my @content_types = qw(application/xhtml+xml text/html);
  $Accept = join(', ', @content_types) . ', */*;q=0.5';
  my $re = join('|', map { s/\+/\\+/g; $_ } @content_types);
  $ContentTypes = qr{\b(?:$re)\b}io;

  my $defaultconfig = '/etc/w3c/checklink.conf';

  eval {
    my %config_opts =
      ( -ConfigFile  => $ENV{W3C_CHECKLINK_CFG} || $defaultconfig,
        -SplitPolicy => 'equalsign',
      );
    %Cfg = Config::General->new(%config_opts)->getall();
  };
  if ($@) {
    die <<".EOF.";
Couldn't read configuration.  Set the W3C_CHECKLINK_CFG environment variable
or copy a configuration file into $defaultconfig and make sure it is
readable by the user executing this script.  The reported error was:
$@
.EOF.
  }

  # Trusted environment variables that need laundering in taint mode.
  foreach (qw(NNTPSERVER NEWSHOST)) {
    ($ENV{$_}) = ($ENV{$_} =~ /^(.*)$/) if $ENV{$_};
  }

  # Use passive FTP by default, see Net::FTP(3).
  $ENV{FTP_PASSIVE} = 1 unless exists($ENV{FTP_PASSIVE});
}

# Autoflush
$| = 1;

# Different options specified by the user
my %Opts =
  ( Command_Line      =>
    ! ($ENV{GATEWAY_INTERFACE} && $ENV{GATEWAY_INTERFACE} =~ /^CGI/),
    Quiet             => 0,
    Summary_Only      => 0,
    Verbose           => 0,
    Progress          => 0,
    HTML              => 0,
    Timeout           => 60,
    Redirects         => 1,
    Dir_Redirects     => 1,
    Accept_Language   => 1,
    Languages         => $ENV{HTTP_ACCEPT_LANGUAGE} || '*',
    HTTP_Proxy        => undef,
    Hide_Same_Realm   => 0,
    Depth             => 0,    # -1 means unlimited recursion.
    Sleep_Time        => 3,    # For the online version.
    Max_Documents     => 150,  # Ditto.
    User              => undef,
    Password          => undef,
    Base_Location     => '.',
    Masquerade        => 0,
    Masquerade_From   => '',
    Masquerade_To     => '',
    Trusted           => $Cfg{Trusted},
  );

# Global variables
# What is our query?
my $query;
# What URI's did we process? (used for recursive mode)
my %processed;
# Result of the HTTP query
my %results;
# List of redirects
my %redirects;
# Count of the number of documents checked
my $doc_count = 0;
# Time stamp
my $timestamp = &get_timestamp();

if ($Opts{Command_Line}) {

  # Parse command line
  &parse_arguments();
  &ask_password() if ($Opts{User} && !$Opts{Password});

  my $first = 1;
  foreach my $uri (@ARGV) {
    if (!$Opts{Summary_Only}) {
      printf("%s %s\n", $PROGRAM, $REVISION) unless $Opts{HTML};
    } else {
      $Opts{Verbose} = 0;
      $Opts{Progress} = 0;
    }
    # Transform the parameter into a URI
    $uri = &urize($uri);
    &check_uri($uri, ($Opts{HTML} && $first), $Opts{Depth});
    $first &&= 0;
  }
  undef $first;

  if ($Opts{HTML}) {
    &html_footer();
  } elsif (($doc_count > 0) && !$Opts{Summary_Only}) {
    printf("\n%s\n", &global_stats());
  }

} else {

  use CGI ();
  use CGI::Carp qw(fatalsToBrowser);
  $query = new CGI;
  # Set a few parameters in CGI mode
  $Opts{Verbose}   = 0;
  $Opts{Progress}  = 0;
  $Opts{HTML}      = 1;

  # Backwards compatibility
  if ($query->param('hide_dir_redirects')) {
    $query->param('hide_redirects', 'on');
    $query->param('hide_type', 'dir');
    $query->delete('hide_dir_redirects');
  }
  if (my $uri = $query->param('url')) {
    $query->param('uri', $uri) unless $query->param('uri');
    $query->delete('url');
  }

  # Override undefined values from the cookie, if we got one.
  if (my %cookie = $query->cookie($AGENT)) {
    while (my ($key, $value) = each %cookie) {
      $query->param($key, $value) unless defined($query->param($key));
    }
  }

  $Opts{Summary_Only} = 1 if $query->param('summary');

  if ($query->param('hide_redirects')) {
    $Opts{Dir_Redirects} = 0;
    if (my $type = $query->param('hide_type')) {
      $Opts{Redirects} = 0 if ($type ne 'dir');
    } else {
      $Opts{Redirects} = 0;
    }
  }

  $Opts{Accept_Language} = 0 if ($query->param('no_accept_language'));

  $Opts{Depth} = -1 if ($query->param('recursive') && $Opts{Depth} == 0);
  if ($query->param('depth') && ($query->param('depth') != 0)) {
    $Opts{Depth} = $query->param('depth');
  }

  # Save, clear or leave cookie as is.
  my $cookie = '';
  if (my $action = $query->param('cookie')) {
    my %cookie = (-name => $AGENT);
    if ($action eq 'clear') {
      # Clear the cookie.
      $cookie{-value}   = '';
      $cookie{-expires} = '-1M';
    } else {
      # Always refresh the expiration time.
      $cookie{-expires} = '+1M';
      if ($action eq 'set') {
        # Set the options.
        my %options = $query->Vars();
        delete($options{$_}) for qw(url uri check cookie); # Non-persistent.
        $cookie{-value}   = \%options;
      } else {
        # Use the old values.
        $cookie{-value} = { $query->cookie($AGENT) };
      }
    }
    $cookie = $query->cookie(%cookie);
  }

  my $uri = $query->param('uri');

  if (! $uri) {
    &html_header('', 1); # Set cookie only from results page.
    &print_form($query);
    &html_footer();
    exit;
  }

  undef $query; # Not needed any more.

  # All Apache configurations don't set HTTP_AUTHORIZATION for CGI scripts.
  # If we're under mod_perl, there is a way around it...
  if ($ENV{MOD_PERL}) {
    my $auth = Apache->request()->header_in('Authorization');
    $ENV{HTTP_AUTHORIZATION} ||= $auth if $auth;
  }

  $uri =~ s/^\s+//g;
  if ($uri =~ m/^file:/) {
    # Only the http scheme is allowed
    &file_uri($uri);
  } elsif ($uri !~ m/:/) {
    if ($uri =~ m|^//|) {
      $uri = 'http:'.$uri;
    } else {
      $uri = 'http://'.$uri;
    }
  }

  &check_uri($uri, 1, $Opts{Depth}, $cookie);
  &html_footer();
}

###############################################################################

################################
# Command line and usage stuff #
################################

sub parse_arguments ()
{

  require Getopt::Long;
  Getopt::Long->require_version(2.17);
  Getopt::Long->import('GetOptions');
  Getopt::Long::Configure('bundling', 'no_ignore_case');
  my @masq = ();

  GetOptions('help|?'          => sub { usage(0) },
             'q|quiet'         => sub { $Opts{Quiet} = 1;
                                        $Opts{Summary_Only} = 1;
                                      },
             's|summary'       => \$Opts{Summary_Only},
             'b|broken'        => sub { $Opts{Redirects} = 0;
                                        $Opts{Dir_Redirects} = 0;
                                      },
             'e|dir-redirects' => sub { $Opts{Dir_Redirects} = 0; },
             'v|verbose'       => \$Opts{Verbose},
             'i|indicator'     => \$Opts{Progress},
             'h|html'          => \$Opts{HTML},
             'n|noacclanguage' => sub { $Opts{Accept_Language} = 0; },
             'r|recursive'     => sub { $Opts{Depth} = -1
                                          if $Opts{Depth} == 0; },
             'l|location=s'    => \$Opts{Base_Location},
             'u|user=s'        => \$Opts{User},
             'p|password=s'    => \$Opts{Password},
             't|timeout=i'     => \$Opts{Timeout},
             'L|languages=s'   => \$Opts{Languages},
             'D|depth=i'       => sub { $Opts{Depth} = $_[1]
                                          unless $_[1] == 0; },
             'd|domain=s'      => \$Opts{Trusted},
             'y|proxy=s'       => \$Opts{HTTP_Proxy},
             'masquerade'      => \@masq,
             'hide-same-realm' => \$Opts{Hide_Same_Realm},
             'V|version'       => \&version,
            )
    || usage(1);

  if (@masq) {
    $Opts{Masquerade} = 1;
    $Opts{Masquerade_To} = shift(@masq);
    $Opts{Masquerade_From} = shift(@masq);
  }
}

sub version ()
{
  print STDERR "$PROGRAM $REVISION\n";
  exit(0);
}

sub usage ()
{
  my ($exitval) = @_;
  $exitval = 0 unless defined($exitval);

  my $langs = defined($Opts{Languages}) ? " (default: $Opts{Languages})" : '';
  my $trust = defined($Opts{Trusted})   ? " (default: $Opts{Trusted})"   : '';

  print STDERR "$PROGRAM $REVISION

Usage: checklink <options> <uris>
Options:
  -s/--summary              Result summary only.
  -b/--broken               Show only the broken links, not the redirects.
  -e/--directory            Hide directory redirects, for example
                            http://www.w3.org/TR -> http://www.w3.org/TR/
  -r/--recursive            Check the documents linked from the first one.
  -D/--depth n              Check the documents linked from the first one
                            to depth n (implies --recursive).
  -l/--location uri         Scope of the documents checked in recursive mode.
                            By default, for example for
                            http://www.w3.org/TR/html4/Overview.html
                            it would be http://www.w3.org/TR/html4/
  -n/--noacclanguage        Do not send an Accept-Language header.
  -L/--languages            Languages accepted$langs.
  -q/--quiet                No output if no errors are found.  Implies -s.
  -v/--verbose              Verbose mode.
  -i/--indicator            Show progress while parsing.
  -u/--user username        Specify a username for authentication.
  -p/--password password    Specify a password.
  --hide-same-realm         Hide 401's that are in the same realm as the
                            document checked.
  -t/--timeout value        Timeout for HTTP requests.
  -d/--domain domain        Regular expression describing the domain to
                            which the authentication information will be
                            sent$trust.
  --masquerade base1 base2  Masquerade base URI base1 as base2
                            (e.g. /home/hugo/MathML2/ is in fact
                            http://www.w3.org/TR/MathML2/).
  -y/--proxy proxy          Specify an HTTP proxy server.
  -h/--html                 HTML output.
  -?/--help                 Show this message.
  -V/--version              Output version information.

See \"perldoc Net::FTP\" for information about various environment variables
affecting FTP connections and \"perldoc Net::NNTP\" for setting a default
NNTP server for news: URIs.

Documentation at: http://www.w3.org/2000/07/checklink
Please send bug reports and comments to the www-validator mailing list:
  www-validator\@w3.org (with 'checklink' in the subject)
  Archives are at: http://lists.w3.org/Archives/Public/www-validator/
";
  exit $exitval;
}

sub ask_password ()
{
  printf(STDERR 'Enter the password for user %s: ', $Opts{User});
  $Have_ReadKey ? ReadMode('noecho',  *STDIN) : system('stty -echo');
  chomp($Opts{Password} = <STDIN>);
  $Have_ReadKey ? ReadMode('restore', *STDIN) : system('stty echo');
  print(STDERR "ok.\n");
}

###############################################################################

###########################################
# Transform foo into file://localhost/foo #
###########################################

sub urize ($)
{
  my $u = URI->new_abs(URI::Escape::uri_unescape($_[0]), URI::file->cwd());
  return $u->as_string();
}

########################################
# Check for broken links in a resource #
########################################

sub check_uri ($$$;$)
{
  my ($uri, $html_header, $depth, $cookie) = @_;
  # If $html_header equals 1, we need to generate a HTML header (first
  # instance called in HTML mode).

  my $start = &get_timestamp() unless $Opts{Quiet};

  # Get and parse the document
  my $response = &get_document('GET', $uri, $doc_count, \%redirects);

  # Can we check the resource? If not, we exit here...
  return -1 if defined($response->{Stop});

  # We are checking a new document
  $doc_count++;

  if ($Opts{HTML}) {
    &html_header($uri, 0, $cookie) if $html_header;
    print('<h2>');
  }

  my $absolute_uri = $response->{absolute_uri}->as_string();

  my $result_anchor = 'results'.$doc_count;

  printf("\nProcessing\t%s\n\n",
         $Opts{HTML} ? &show_url(&encode($absolute_uri)) : $absolute_uri);

  if ($Opts{HTML}) {
    print("</h2>\n");
    if (! $Opts{Summary_Only}) {
      printf("<p>Go to <a href=\"#%s\">the results</a>.</p>\n",
             $result_anchor);
      printf("<p>For reliable link checking results, check
<a href=\"check?uri=%s\">HTML Validity</a> first.  See also
<a href=\"http://jigsaw.w3.org/css-validator/validator?uri=%s\">CSS Validity</a>.</p>
<p>Back to the <a href=\"checklink\">link checker</a>.</p>\n",
             map{&encode(URI::Escape::uri_escape($absolute_uri,
                                                 "^A-Za-z0-9."))}(1..2));
      print("<pre>\n");
    }
  }

  # Record that we have processed this resource
  $processed{$absolute_uri} = 1;
  # Parse the document
  my $p = &parse_document($uri, $absolute_uri,
                          $response->content(), 1,
                          $depth != 0);
  my $base = URI->new($p->{base});

  # Check anchors
  ###############

  print "Checking anchors...\n" unless $Opts{Summary_Only};

  my %errors;
  foreach my $anchor (keys %{$p->{Anchors}}) {
    my $times = 0;
    foreach my $l (keys %{$p->{Anchors}{$anchor}}) {
      $times += $p->{Anchors}{$anchor}{$l};
    }
    # They should appear only once
    $errors{$anchor} = 1 if ($times > 1);
    # Empty IDREF's are not allowed
    $errors{$anchor} = 1 if ($anchor eq '');
  }
  print " done.\n" unless $Opts{Summary_Only};

  # Check links
  #############

  my %links;
  # Record all the links found
  foreach my $link (keys %{$p->{Links}}) {
    my $link_uri = URI->new($link);
    my $abs_link_uri = URI->new_abs($link_uri, $base);
    if ($Opts{Masquerade}) {
      if ($abs_link_uri =~ m|^$Opts{Masquerade_From}|) {
        printf("processing %s in base %s\n",
               $abs_link_uri, $Opts{Masquerade_To});
        my $nlink = $abs_link_uri;
        $nlink =~
          s|^$Opts{Masquerade_From}|$Opts{Masquerade_To}|;
        $abs_link_uri = URI->new($nlink);
      };
    }
    foreach my $lines (keys %{$p->{Links}{$link}}) {
      my $canonical = URI->new($abs_link_uri->canonical());
      my $url = $canonical->scheme().':'.$canonical->opaque();
      my $fragment = $canonical->fragment();
      if (! $fragment) {
        # Document without fragment
        $links{$url}{location}{$lines} = 1;
      } else {
        # Resource with a fragment
        $links{$url}{fragments}{$fragment}{$lines} = 1;
      }
    }
  }

  # Build the list of broken URI's
  my %broken;
  foreach my $u (keys %links) {

    # Don't check mailto: URI's
    next if ($u =~ m/^mailto:/);

    &hprintf("Checking link %s\n", $u) unless $Opts{Summary_Only};

    # Check that a link is valid
    &check_validity($uri, $u, \%links, \%redirects);
    &hprintf("\tReturn code: %s\n", $results{$u}{location}{code})
      if ($Opts{Verbose});
    if ($results{$u}{location}{success}) {

      # Even though it was not broken, we might want to display it
      # on the results page (e.g. because it required authentication)
      $broken{$u}{location} = 1 if ($results{$u}{location}{display} >= 400);

      # List the broken fragments
      foreach my $fragment (keys %{$links{$u}{fragments}}) {
        if ($Opts{Verbose}) {
          my @frags = sort keys %{$links{$u}{fragments}{$fragment}};
          &hprintf("\t\t%s %s - Line%s: %s\n",
                   $fragment,
                   ($results{$u}{fragments}{$fragment}) ? 'OK' : 'Not found',
                   (scalar(@frags) > 1) ? 's' : '',
                   join(', ', @frags)
                  );
        }
        # A broken fragment?
        if ($results{$u}{fragments}{$fragment} == 0) {
          $broken{$u}{fragments}{$fragment} += 2;
        }
      }
    } else {
      # Couldn't find the document
      $broken{$u}{location} = 1;
      # All the fragments associated are hence broken
      foreach my $fragment (keys %{$links{$u}{fragments}}) {
        $broken{$u}{fragments}{$fragment}++;
      }
    }
  }
  &hprintf("Processed in %ss.\n", &time_diff($start, &get_timestamp()))
    unless $Opts{Summary_Only};

  # Display results
  if ($Opts{HTML} && !$Opts{Summary_Only}) {
    print("</pre>\n");
    printf("<h2><a name=\"%s\">Results</a></h2>\n", $result_anchor);
  }
  print "\n" unless $Opts{Quiet};

  &anchors_summary($p->{Anchors}, \%errors);
  &links_summary(\%links, \%results, \%broken, \%redirects);

  # Do we want to process other documents?
  if ($depth != 0) {
    if (! ref($Opts{Base_Location})) { # Not a URI object yet?
      $Opts{Base_Location} = ($Opts{Base_Location} eq '.')
        ? URI->new($results{$uri}{parsing}{base})->canonical() :
          URI->new($Opts{Base_Location})->canonical();
    }

    foreach my $u (keys %links) {

      next unless $results{$u}{location}{success};  # Broken link?

      # Check if this link is in our recursion scope (see URI docs).
      my $current = URI->new($u)->canonical();
      my $rel = $current->rel($Opts{Base_Location}); # base -> current !
      next if ($current eq $rel);                 # Relative path not possible?
      next if ($rel =~ m|^(\.\.)?/|);    # Relative path starts with ../ or / ?
      undef $current; undef $rel;

      # Do we understand its content type?
      next unless ($results{$u}{location}{type} =~ $ContentTypes);

      # Have we already processed this URI?
      next if &already_processed($u);

      # Do the job
      print "\n";
      if (! $Opts{HTML}) {
        print '-' x 40;
      } else {
        # For the online version, wait for a while to avoid abuses
        if (!$Opts{Command_Line}) {
          if ($doc_count == $Opts{Max_Documents}) {
            print("<hr>\n<p><strong>Maximum number of documents reached!</strong></p>\n");
          }
          if ($doc_count >= $Opts{Max_Documents}) {
            $doc_count++;
            print("<p>Not checking <strong>$u</strong></p>\n");
            $processed{$u} = 1;
            next;
          }
        }
        print('<hr>');
        sleep($Opts{Sleep_Time});
      }
      print "\n";
      if ($depth < 0) {
        &check_uri($u, 0, -1);
      } else {
        &check_uri($u, 0, $depth-1);
      }
    }
  }
}

#######################################
# Get and parse a resource to process #
#######################################

sub get_document ($$$;\%)
{
  my ($method, $uri, $in_recursion, $redirects) = @_;
  # $method contains the HTTP method the use (GET or HEAD)
  # $uri contains the identifier of the resource
  # $in_recursion equals 1 if we are in recursion mode (i.e. it is at least
  #                        the second resource checked)
  # $redirects is a pointer to the hash containing the map of the redirects

  # Get the resource
  my $response;
  if (defined($results{$uri}{response})
      && !(($method eq 'GET') && ($results{$uri}{method} eq 'HEAD'))) {
    $response = $results{$uri}{response};
  } else {
    $response = &get_uri($method, $uri);
    &record_results($uri, $method, $response);
    &record_redirects($redirects, $response->{Redirects});
  }
  if (! $response->is_success()) {
    if (! $in_recursion) {
      # Is it too late to request authentication?
      if ($response->code() == 401) {
        &authentication($response);
      } else {
        &html_header($uri) if $Opts{HTML};
        &hprintf("\nError: %d %s\n",
                 $response->code(), $response->message());
      }
    }
    $response->{Stop} = 1;
    return($response);
  }

  # What is the URI of the resource that we are processing by the way?
  my $base_uri = URI->new($response->base());
  my $request_uri = URI->new($response->request->url);
  $response->{absolute_uri} = $base_uri->abs($request_uri);

  # Can we parse the document?
  my $failed_reason;
  if ((my $ct = $response->header('Content-Type')) !~ $ContentTypes) {
    $failed_reason = "Content-Type is '$ct'";
  } elsif ($response->header('Content-Encoding') &&
           ((my $ce = $response->header('Content-Encoding')) ne 'identity')) {
    # @@@ We could maybe handle gzip...
    $failed_reason = "Content-Encoding is '$ce'";
  }
  if ($failed_reason) {
    # No, there is a problem...
    if (! $in_recursion) {
      &html_header($uri) if $Opts{HTML};
      &hprintf("Can't check links: %s.\n", $failed_reason);
    }
    $response->{Stop} = 1;
  }

  # Ok, return the information
  return($response);
}

##################################################
# Check whether a URI has already been processed #
##################################################

sub already_processed ($)
{
  my ($uri) = @_;
  # Don't be verbose for that part...
  my $summary_value = $Opts{Summary_Only};
  $Opts{Summary_Only} = 1;
  # Do a GET: if it fails, we stop, if not, the results are cached
  my $response = &get_document('GET', $uri, 1);
  # ... but just for that part
  $Opts{Summary_Only} = $summary_value;
  # Can we process the resource?
  return -1 if defined($response->{Stop});
  # Have we already processed it?
  return  1 if defined($processed{$response->{absolute_uri}->as_string()});
  # It's not processed yet and it is processable: return 0
  return  0;
}

############################
# Get the content of a URI #
############################

sub get_uri ($$;$\%$$$$)
{
  # Here we have a lot of extra parameters in order not to lose information
  # if the function is called several times (401's)
  my ($method, $uri, $start, $redirects, $code, $realm, $message, $auth) = @_;

  # $method contains the method used
  # $uri contains the target of the request
  # $start is a timestamp (not defined the first time the function is
  #                        called)
  # $redirects is a map of redirects
  # $code is the first HTTP return code
  # $realm is the realm of the request
  # $message is the HTTP message received
  # $auth equals 1 if we want to send out authentication information

  # For timing purposes
  $start = &get_timestamp() unless defined($start);

  # Prepare the query
  my %lwpargs = ($LWP::VERSION >= 5.6) ? (keep_alive => 1) : ();
  my $ua = W3C::UserAgent->new(%lwpargs);
  $ua->timeout($Opts{Timeout});
  $ua->agent(sprintf('%s/%s %s', $AGENT, $CVS_VERSION, $ua->agent()));
  $ua->env_proxy();
  $ua->proxy('http', 'http://' . $Opts{HTTP_Proxy}) if $Opts{HTTP_Proxy};

  # $ua->{fetching} contains the URI we originally wanted
  # $ua->{uri} is modified in the case of a redirect; this is used to
  # build $ua->{Redirects}
  $ua->{uri} = $ua->{fetching} = $uri;
  $ua->{Redirects} = $redirects if defined($redirects);

  # Do we want printouts of progress?
  my $verbose_progress =
    ! ($Opts{Summary_Only} || (!$doc_count && $Opts{HTML}));

  &hprintf("%s %s ", $method, $uri) if $verbose_progress;

  my $request = new HTTP::Request($method, $uri);
  if ($Opts{Accept_Language} && $Opts{Languages}) {
    $request->header('Accept-Language' => $Opts{Languages});
  }
  $request->header('Accept', $Accept);
  # Are we providing authentication info?
  if ($auth && $request->url()->host() =~ /$Opts{Trusted}/i) {
    if (defined($ENV{HTTP_AUTHORIZATION})) {
      $request->headers->header(Authorization => $ENV{HTTP_AUTHORIZATION});
    } elsif (defined($Opts{User}) && defined($Opts{Password})) {
      $request->authorization_basic($Opts{User}, $Opts{Password});
    }
  }

  # Tell the user agent if we want progress reports (in redirects) or not.
  $ua->{Checklink_verbose_progress} = $verbose_progress;

  # Do the query
  my $response = $ua->request($request);

  # Get the results
  # Record the very first response
  if (! defined($code)) {
    $code = $ua->{FirstResponse};
    $message = $ua->{FirstMessage};
  }
  # Authentication requested?
  if ($response->code() == 401 &&
      !defined($auth) &&
      (defined($ENV{HTTP_AUTHORIZATION})
       || (defined($Opts{User}) && defined($Opts{Password})))) {

    # Set host as trusted domain unless we already have one.
    $Opts{Trusted} ||= sprintf('^%s$', quotemeta($response->base()->host()));

    # Deal with authentication and avoid loops
    if (! defined($realm)) {
      $response->headers->www_authenticate =~ /Basic realm=\"([^\"]+)\"/;
      $realm = $1;
    }
    print "\n" if $verbose_progress;
    return &get_uri($method, $response->request->url,
                    $start, $ua->{Redirects},
                    $code, $realm, $message, 1);
  }
  # Record the redirects
  $response->{Redirects} = $ua->{Redirects};
  &hprintf(" fetched in %ss\n",
           &time_diff($start, &get_timestamp())) if $verbose_progress;

  $response->{OriginalCode}    = $code;
  $response->{OriginalMessage} = $message;
  $response->{Realm}           = $realm if defined($realm);

  return $response;
}

#########################################
# Record the results of an HTTP request #
#########################################

sub record_results ($$$)
{
  my ($uri, $method, $response) = @_;
  $results{$uri}{response} = $response;
  $results{$uri}{method} = $method;
  $results{$uri}{location}{code} = $response->code();
  $results{$uri}{location}{type} = $response->header('Content-type');
  $results{$uri}{location}{display} = $results{$uri}{location}{code};
  $results{$uri}{location}{orig} = $response->{OriginalCode};
  # Did we get a redirect?
  if ($response->{OriginalCode} != $response->code()) {
    $results{$uri}{location}{orig_message} =  $response->{OriginalMessage};
    $results{$uri}{location}{redirected} = 1;
  }
  $results{$uri}{location}{success} = $response->is_success();
  # Stores the authentication information
  if (defined($response->{Realm})) {
    $results{$uri}{location}{realm} = $response->{Realm};
    $results{$uri}{location}{display} = 401 unless $Opts{Hide_Same_Realm};
  }
  # What type of broken link is it? (stored in {record} - the {display}
  #              information is just for visual use only)
  if (($results{$uri}{location}{display} == 401)
      && ($results{$uri}{location}{code} == 404)) {
    $results{$uri}{location}{record} = 404;
  } else {
    $results{$uri}{location}{record} = $results{$uri}{location}{display};
  }
  # Did it fail?
  $results{$uri}{location}{message} = $response->message();
  if (! $results{$uri}{location}{success}) {
    &hprintf("Error: %d %s\n",
             $results{$uri}{location}{code},
             $results{$uri}{location}{message})
      if ($Opts{Verbose});
    return;
  }
}

####################
# Parse a document #
####################

sub parse_document ($$$$;$)
{
  my ($uri, $location, $document, $links, $rec_needs_links) = @_;

  my $p;

  if (defined($results{$uri}{parsing})) {
    # We have already done the job. Woohoo!
    $p->{base} = $results{$uri}{parsing}{base};
    $p->{Anchors} = $results{$uri}{parsing}{Anchors};
    $p->{Links} = $results{$uri}{parsing}{Links};
    return $p;
  }

  my $start;
  $p = W3C::CheckLink->new();
  $p->{base} = $location;
  if (! $Opts{Summary_Only}) {
    $start = &get_timestamp();
    print("Parsing...\n");
  }
  if (!$Opts{Summary_Only} || $Opts{Progress}) {
    $p->{Total} = ($document =~ tr/\n//);
  }
  # We only look for anchors if we are not interested in the links
  # obviously, or if we are running a recursive checking because we
  # might need this information later
  $p->{only_anchors} = !($links || $rec_needs_links);

  # Transform <?xml:stylesheet ...?> into <xml:stylesheet ...> for parsing
  # Processing instructions are not parsed by process, but in this case
  # it should be. It's expensive, it's horrible, but it's the easiest way
  # for right now.
  $document =~ s/\<\?(xml:stylesheet.*?)\?\>/\<$1\>/ unless $p->{only_anchors};

  $p->parse($document);

  if (! $Opts{Summary_Only}) {
    my $stop = &get_timestamp();
    print "\r" if $Opts{Progress};
    &hprintf(" done (%d lines in %ss).\n",
             $p->{Total}, &time_diff($start, $stop));
  }

  # Save the results before exiting
  $results{$uri}{parsing}{base} = $p->{base};
  $results{$uri}{parsing}{Anchors} = $p->{Anchors};
  $results{$uri}{parsing}{Links} = $p->{Links};

  return $p;
}

###################################
# Constructor for W3C::CheckLink #
###################################

sub new
{
  my $p = HTML::Parser::new(@_, api_version => 3);

  # Start tags
  $p->handler(start => 'start', 'self, tagname, attr, text, event, tokens');
  # Declarations
  $p->handler(declaration =>
              sub {
                my $self = shift;
                $self->declaration(substr($_[0], 2, -1));
              }, 'self, text');
  # Other stuff
  $p->handler(default => 'text', 'self, text');
  # Line count
  $p->{Line} = 1;
  # Check <a [..] name="...">?
  $p->{check_name} = 1;
  # Check <[..] id="..">?
  $p->{check_id} = 1;
  # Don't interpret comment loosely
  $p->strict_comment(1);

  return $p;
}

#################################################
# Record or return  the doctype of the document #
#################################################

sub doctype
{
  my ($self, $dc) = @_;
  return $self->{doctype} unless $dc;
  $_ = $self->{doctype} = $dc;

  # What to look for depending on the doctype
  $self->{check_name} = 0 if ($_ eq '-//W3C//DTD XHTML Basic 1.0//EN');

  # Check for the id tag
  if (
      # HTML 2.0 & 3.0
      m%^-//IETF//DTD HTML [23]\.0//% ||
      # HTML 3.2
      m%^-//W3C//DTD HTML 3\.2//%) {
    $self->{check_id} = 0;
  }
  # Enable XML extensions
  $self->xml_mode(1) if (m%^-//W3C//DTD XHTML %);
}

#######################################
# Count the number of lines in a file #
#######################################

sub new_line
{
  my ($self, $string) = @_;
  my $count = ($string =~ tr/\n//);
  $self->{Line} = $self->{Line} + $count;
  printf("\r%4d%%", int($self->{Line}/$self->{Total}*100)) if $Opts{Progress};
}

#############################
# Extraction of the anchors #
#############################

sub get_anchor
{
  my ($self, $tag, $attr) = @_;

  my $anchor = $attr->{id} if $self->{check_id};
  if ($self->{check_name} && ($tag eq 'a')) {
    # @@@@ In XHTML, <a name="foo" id="foo"> is mandatory
    # Force an error if it's not the case (or if id's and name's values
    #                                      are different)
    # If id is defined, name if defined must have the same value
    $anchor ||= $attr->{name};
  }

  return $anchor;
}

###########################
# W3C::CheckLink handlers #
###########################

sub add_link
{
  my ($self, $uri) = @_;
  $self->{Links}{$uri}{$self->{Line}}++ if defined($uri);
}

sub start
{
  my ($self, $tag, $attr, $text) = @_;

  # Anchors
  my $anchor = $self->get_anchor($tag, $attr);
  $self->{Anchors}{$anchor}{$self->{Line}}++ if defined($anchor);

  # Links
  if (!$self->{only_anchors}) {
    # Here, we are checking too many things
    # The right thing to do is to parse the DTD...
    if ($tag eq 'base') {
      # Treat <base> (without href) or <base href=""> as if it didn't exist.
      if (defined($attr->{href}) && $attr->{href} ne '') {
        $self->{base} = $attr->{href};
      }
    } else {
      $self->add_link($attr->{href});
    }
    $self->add_link($attr->{src});
    $self->add_link($attr->{data}) if ($tag eq 'object');
    $self->add_link($attr->{cite}) if ($tag eq 'blockquote');
  }

  # Line counting
  $self->new_line($text) if ($text =~ m/\n/);
}

sub text
{
  my ($self, $text) = @_;
  if (!$Opts{Progress}) {
    # If we are just extracting information about anchors,
    # parsing this part is only cosmetic (progress indicator)
    return unless !$self->{only_anchors};
  }
  $self->new_line($text) if ($text =~ /\n/);
}

sub declaration
{
  my ($self, $text) = @_;
  # Extract the doctype
  my @declaration = split(/\s+/, $text, 4);
  if (($#declaration >= 3) &&
      ($declaration[0] eq 'DOCTYPE') &&
      (lc($declaration[1]) eq 'html')) {
    # Parse the doctype declaration
    $text =~ m/^DOCTYPE\s+html\s+PUBLIC\s+\"([^\"]*)\"(\s+\"([^\"]*)\")?\s*$/i;
    # Store the doctype
    $self->doctype($1) if $1;
    # If there is a link to the DTD, record it
    $self->{Links}{$3}{$self->{Line}}++ if (!$self->{only_anchors} && $3);
  }
  return unless !$self->{only_anchors};
  $self->text($text);
}

################################
# Check the validity of a link #
################################

sub check_validity ($$\%\%)
{
  my ($testing, $uri, $links, $redirects) = @_;
  # $testing is the URI of the document checked
  # $uri is the URI of the target that we are verifying
  # $links is a hash of the links in the documents checked
  # $redirects is a map of the redirects encountered

  # Checking file: URI's is not allowed with a CGI
  if ($testing ne $uri) {
    if (!$Opts{Command_Line} && $testing !~ m/^file:/ && $uri =~ m/^file:/) {
      my $msg = 'Error: \'file:\' URI not allowed';
      # Can't test? Return 400 Bad request.
      $results{$uri}{location}{code}    = 400;
      $results{$uri}{location}{record}  = 400;
      $results{$uri}{location}{orig}    = 400;
      $results{$uri}{location}{success} = 0;
      $results{$uri}{location}{message} = $msg;
      &hprintf("Error: %d %s\n", 400, $msg) if $Opts{Verbose};
      return;
    }
  }

  # Get the document with the appropriate method
  # Only use GET if there are fragments. HEAD is enough if it's not the
  # case.
  my @fragments = keys %{$links->{$uri}{fragments}};
  my $method = scalar(@fragments) ? 'GET' : 'HEAD';

  my $response;
  my $being_processed = 0;
  if ((! defined($results{$uri}))
      || (($method eq 'GET') && ($results{$uri}{method} eq 'HEAD'))) {
    $being_processed = 1;
    $response = &get_uri($method, $uri);
    # Get the information back from get_uri()
    &record_results($uri, $method, $response);
    # Record the redirects
    &record_redirects($redirects, $response->{Redirects});
  }

  # We got the response of the HTTP request. Stop here if it was a HEAD.
  return if ($method eq 'HEAD');

  # There are fragments. Parse the document.
  my $p;
  if ($being_processed) {
    # Can we really parse the document?
    return unless defined($results{$uri}{location}{type});
    if ($results{$uri}{location}{type} !~ $ContentTypes) {
      &hprintf("Can't check content: Content-Type is '%s'.\n",
               $results{$uri}{location}{type})
        if ($Opts{Verbose});
      return;
    }
    # Do it then
    $p = &parse_document($uri, $response->base(),
                         $response->as_string(), 0);
  } else {
    # We already had the information
    $p->{Anchors} = $results{$uri}{parsing}{Anchors};
  }
  # Check that the fragments exist
  foreach my $fragment (keys %{$links->{$uri}{fragments}}) {
    if (defined($p->{Anchors}{$fragment})
        || &escape_match($fragment, $p->{Anchors})) {
      $results{$uri}{fragments}{$fragment} = 1;
    } else {
      $results{$uri}{fragments}{$fragment} = 0;
    }
  }
}

sub escape_match ($\%)
{
  my ($a, $hash) = (URI::Escape::uri_unescape($_[0]), $_[1]);
  foreach my $b (keys %$hash) {
    return 1 if ($a eq URI::Escape::uri_unescape($b));
  }
  return 0;
}

##########################
# Ask for authentication #
##########################

sub authentication ($)
{
  my $r = $_[0];
  $r->headers->www_authenticate =~ /Basic realm=\"([^\"]+)\"/;
  my $realm = $1;

  if ($Opts{Command_Line}) {
    printf STDERR <<EOF, $r->request()->url(), $realm;

Authentication is required for %s.
The realm is %s.
Use the -u and -p options to specify a username and password and the -d option
to specify trusted domains.
EOF
  } else {

    printf("Status: 401 Authorization Required\nWWW-Authenticate: %s\nConnection: close\nContent-Language: en\nContent-Type: text/html; charset=iso-8859-1\n\n", $r->headers->www_authenticate);

    printf("%s
<html lang=\"en\">
<head>
<title>401 Authorization Required</title>
</head>
<body>
<h1>Authorization Required</h1>
<p>
  You need %s access to %s to perform Link Checking.<br>
", $DocType, &encode($realm), $r->request->url);

    if ($Opts{Trusted}) {
      printf <<EOF, &encode($Opts{Trusted});
  This service has been configured to send authentication only to hostnames
  matching the regular expression <code>%s</code>
EOF
    }

    print "</p>\n";
  }
}

##################
# Get statistics #
##################

sub get_timestamp ()
{
  return pack('LL', Time::HiRes::gettimeofday());
}

sub time_diff ($$)
{
  my @start = unpack('LL', $_[0]);
  my @stop = unpack('LL', $_[1]);
  for ($start[1], $stop[1]) {
    $_ /= 1_000_000;
  }
  return(sprintf("%.1f", ($stop[0]+$stop[1])-($start[0]+$start[1])));
}

########################
# Handle the redirects #
########################

# Record the redirects in a hash
sub record_redirects (\%\%)
{
  my ($redirects, $sub) = @_;
  foreach my $r (keys %$sub) {
    $redirects->{$r} = $sub->{$r};
  }
}

# Determine if a request is redirected
sub is_redirected ($%)
{
  my ($uri, %redirects) = @_;
  return(defined($redirects{$uri}));
}

# Get a list of redirects for a URI
sub get_redirects ($%)
{
  my ($uri, %redirects) = @_;
  my @history = ($uri);
  my $origin = $uri;
  while ($redirects{$uri}) {
    $uri = $redirects{$uri};
    push(@history, $uri);
    last if ($uri eq $origin);
  }
  return(@history);
}

####################################################
# Tool for sorting the unique elements of an array #
####################################################

sub sort_unique (@)
{
  my %saw;
  @saw{@_} = ();
  return (sort { $a <=> $b } keys %saw);
}

#####################
# Print the results #
#####################

sub anchors_summary (\%\%)
{
  my ($anchors, $errors) = @_;

  # Number of anchors found.
  my $n = scalar(keys(%$anchors));
  if (! $Opts{Quiet}) {
    if ($Opts{HTML}) {
      print("<h3>Anchors</h3>\n<p>");
    } else {
      print("Anchors\n\n");
    }
    &hprintf("Found %d anchor%s.", $n, ($n == 1) ? '' : 's');
    print('</p>') if $Opts{HTML};
    print("\n");
  }
  # List of the duplicates, if any.
  my @errors = keys %{$errors};
  if (! scalar(@errors)) {
    print("<p>Valid anchors!</p>\n") if (! $Opts{Quiet} && $Opts{HTML} && $n);
    return;
  }
  undef $n;

  print('<p>') if $Opts{HTML};
  print('List of duplicate and empty anchors');
  print("</p>\n<table border=\"1\">\n<tr><td><b>Anchors</b></td><td><b>Lines</b></td></tr>") if $Opts{HTML};
  print("\n");

  foreach my $anchor (@errors) {
    my $format;
    my @unique = &sort_unique(keys %{$anchors->{$anchor}});
    if ($Opts{HTML}) {
      $format = "<tr class=\"broken\"><td>%s</td><td>%s</td></tr>\n";
    } else {
      my $s = (scalar(@unique) > 1) ? 's' : '';
      $format = "\t%s\tLine$s: %s\n";
    }
    printf($format,
           &encode($anchor eq '' ? 'Empty anchor' : $anchor),
           join(', ', @unique));
  }

  print("</table>\n") if $Opts{HTML};
}

sub show_link_report (\%\%\%\%\@;$\%)
{
  my ($links, $results, $broken, $redirects, $urls, $codes, $todo) = @_;

  print("\n<dl class=\"report\">") if $Opts{HTML};
  print("\n");

  # Process each URL
  my ($c, $previous_c);
  foreach my $u (@$urls) {
    my @fragments = keys %{$broken->{$u}{fragments}};
    # Did we get a redirect?
    my $redirected = &is_redirected($u, %$redirects);
    # List of lines
    my @total_lines;
    foreach my $l (keys %{$links->{$u}{location}}) {
      push (@total_lines, $l);
    }
    foreach my $f (keys %{$links->{$u}{fragments}}) {
      next if ($f eq $u && defined($links->{$u}{$u}{-1}));
      foreach my $l (keys %{$links->{$u}{fragments}{$f}}) {
        push (@total_lines, $l);
      }
    }

    # Error type
    $c = &code_shown($u, $results);
    # What to do
    my $whattodo;
    my $redirect_too;
    if ($todo) {
      if ($u =~ m/^javascript:/) {
        if ($Opts{HTML}) {
          $whattodo =
'You must change this link: people using a browser without Javascript support
will <em>not</em> be able to follow this link. See the
<a href="http://www.w3.org/TR/1999/WAI-WEBCONTENT-19990505/#tech-scripts">Web
Content Accessibility Guidelines on the use of scripting on the Web</a> and
the
<a href="http://www.w3.org/TR/WCAG10-HTML-TECHS/#directly-accessible-scripts">techniques
on how to solve this</a>.';
        } else {
          $whattodo = 'Change this link: people using a browser without Javascript support will not be able to follow this link.';
        }
      } elsif ($c == 500) {
        # 500's could be a real 500 or a DNS lookup problem
        if ($results->{$u}{location}{message} =~
            m/Bad hostname '[^\']*'/) {
          $whattodo = 'The hostname could not be resolved. This link needs to be fixed.';
        } else {
          $whattodo = 'This is a server-side problem. Check the URI.';
        }
      } else {
        $whattodo = $todo->{$c};
      }
      # @@@ 303 and 307 ???
      if (defined($redirects{$u}) && ($c != 301) && ($c != 302)) {
        $redirect_too = 'The original request has been redirected.';
        $whattodo .= ' '.$redirect_too unless $Opts{HTML};
      }
    } else {
      # Directory redirects
      $whattodo = 'Add a trailing slash to the URL.';
    }

    my @unique = &sort_unique(@total_lines);
    my $lines_list = join(', ', @unique);
    my $s = (scalar(@unique) > 1) ? 's' : '';
    undef @unique;

    if ($Opts{HTML}) {
      # Style stuff
      my $idref = '';
      if ($codes && (!defined($previous_c) || ($c != $previous_c))) {
        $idref = ' id="d'.$doc_count.'code_'.$c.'"';
        $previous_c = $c;
      }
      # Main info
      my @redirects_urls = &get_redirects($u, %$redirects);
      for (@redirects_urls) {
        $_ = &show_url($_);
      }
      # HTTP message
      my $http_message;
      if ($results->{$u}{location}{message}) {
        $http_message = &encode($results->{$u}{location}{message});
        if ($c == 404 || $c == 500) {
          $http_message = '<span class="broken">'.
            $http_message.'</span>';
        }
      }
      printf("
<dt%s>%s</dt>
<dd>What to do: <strong%s>%s</strong>%s<br></dd>
<dd>HTTP Code returned: %d%s<br>
HTTP Message: %s%s%s</dd>
<dd>Line%s: %s</dd>\n",
             # Anchor for return codes
             $idref,
             # List of redirects
             $redirected ?
             join(' redirected to<br>', @redirects_urls) : &show_url($u),
             # Color
             &bgcolor($c),
             # What to do
             $whattodo,
             # Redirect too?
             $redirect_too ?
             sprintf(' <span %s>%s</span>', &bgcolor(301), $redirect_too) : '',
             # Original HTTP reply
             $results->{$u}{location}{orig},
             # Final HTTP reply
             ($results->{$u}{location}{code} !=
              $results->{$u}{location}{orig})
             ? ' <span title="redirected to">-&gt;</span> '.
             &encode($results->{$u}{location}{code})
             : '',
             # Realm
             (defined($results->{$u}{location}{realm})
              ? 'Realm: '.&encode($results->{$u}{location}{realm}).'<br>'
              : ''),
             # HTTP original message
             defined($results->{$u}{location}{orig_message})
             ? &encode($results->{$u}{location}{orig_message}).
             ' <span title="redirected to">-&gt;</span> '
             : '',
             # HTTP final message
             $http_message,
             $s,
             # List of lines
             $lines_list);
      if ($#fragments >= 0) {
        my $fragment_direction = '';
        if ($results->{$u}{location}{code} == 200) {
          $fragment_direction =
            ' <strong class="broken">They need to be fixed!</strong>';
        }
        printf("<dd><dl><dt>Broken fragments and their line numbers: %s</dt>\n",
               $fragment_direction);
      }
    } else {
      printf("\n%s\t%s\n  Code: %d%s %s\nTo do: %s\n",
             # List of redirects
             $redirected ? join("\n-> ",
                                &get_redirects($u, %$redirects)) : $u,
             # List of lines
             $lines_list ? "Line$s: $lines_list" : '',
             # Original HTTP reply
             $results->{$u}{location}{orig},
             # Final HTTP reply
             ($results->{$u}{location}{code} != $results->{$u}{location}{orig})
             ? ' -> '.$results->{$u}{location}{code}
             : '',
             # HTTP message
             $results->{$u}{location}{message} ?
             $results->{$u}{location}{message} : '',
             # What to do
             $whattodo);
      if ($#fragments >= 0) {
        if ($results->{$u}{location}{code} == 200) {
          print("The following fragments need to be fixed:\n");
        } else {
          print("Fragments:\n");
        }
      }
    }
    # Fragments
    foreach my $f (@fragments) {
      if ($Opts{HTML}) {
        printf("<dd>%s: %s</dd>\n",
               # Broken fragment
               &show_url($u, $f),
               # List of lines
               join(', ', &sort_unique(keys %{$links->{$u}{fragments}{$f}})));
      } else {
        my @unq = &sort_unique(keys %{$links->{$u}{fragments}{$f}});
        printf("\t%-30s\tLine%s: %s\n",
               # Fragment
               $f,
               # Multiple?
               (scalar(@unq) > 1) ? 's' : '',
               # List of lines
               join(', ', @unq));
      }
    }

    print("</dl></dd>\n") if ($Opts{HTML} && scalar(@fragments));
  }

  # End of the table
  print("</dl>\n") if $Opts{HTML};
}

sub code_shown ($$)
{
  my ($u, $results) = @_;

  if ($results->{$u}{location}{record} == 200) {
    return $results->{$u}{location}{orig};
  } else {
    return $results->{$u}{location}{record};
  }
}

sub links_summary (\%\%\%\%)
{
  # Advices to fix the problems

  my %todo = ( 200 => 'There are broken fragments which must be fixed.',
               300 => 'It usually means that there is a typo in a link that triggers mod_speling action - this must be fixed!',
               301 => 'You should update the link.',
               302 => 'Usually nothing.',
               303 => 'Usually nothing.',
               307 => 'Usually nothing.',
               400 => 'Usually the sign of a malformed URL that cannot be parsed by the server.',
               401 => "The link is not public. You'd better specify it.",
               403 => 'The link is forbidden! This needs fixing. Usual suspects: a missing index.html or Overview.html, or a missing ACL.',
               404 => 'The link is broken. Fix it NOW!',
               405 => 'The server does not allow HEAD requests. Go ask the guys who run this server why. Check the link manually.',
               406 => "The server isn't capable of responding according to the Accept* headers sent. Check it out.",
               407 => 'The link is a proxy, but requires Authentication.',
               408 => 'The request timed out.',
               410 => 'The resource is gone. You should remove this link.',
               415 => 'The media type is not supported.',
               500 => 'Either the hostname is incorrect or it is a server side problem. Check the detailed list.',
               501 => 'Could not check this link: method not implemented or scheme not supported.',
               503 => 'The server cannot service the request, for some unknown reason.');
  my %priority = ( 410 => 1,
                   404 => 2,
                   403 => 5,
                   200 => 10,
                   300 => 15,
                   401 => 20
                 );

  my ($links, $results, $broken, $redirects) = @_;

  # List of the broken links
  my @urls = keys %{$broken};
  my @dir_redirect_urls = ();
  if ($Opts{Redirects}) {
    # Add the redirected URI's to the report
    for my $l (keys %$redirects) {
      next unless (defined($results->{$l})
                   && defined($links->{$l})
                   && !defined($broken->{$l}));
      # Check whether we have a "directory redirect"
      # e.g. http://www.w3.org/TR -> http://www.w3.org/TR/
      my @redirects = &get_redirects($l, %$redirects);
      if (($#redirects == 1)
          && (($redirects[0].'/') eq $redirects[1])) {
        push(@dir_redirect_urls, $l);
        next;
      }
      push(@urls, $l);
    }
  }

  # Broken links and redirects
  if ($#urls < 0) {
    if (! $Opts{Quiet}) {
      if ($Opts{HTML}) {
        print "<h3>Links</h3>\n";
        print "<p>Valid links!</p>";
      } else {
        print "\nValid links.";
      }
      print "\n";
    }
  } else {
    print('<h3>') if $Opts{HTML};
    print("\nList of broken links");
    print(' and redirects') if $Opts{Redirects};

    # Sort the URI's by HTTP Code
    my %code_summary;
    my @idx;
    foreach my $u (@urls) {
      if (defined($results->{$u}{location}{record}))  {
        my $c = &code_shown($u, $results);
        $code_summary{$c}++;
        push(@idx, $c);
      }
    }
    my @sorted = @urls[
                       sort {
                         defined($priority{$idx[$a]}) ?
                           defined($priority{$idx[$b]}) ?
                             $priority{$idx[$a]}
                               <=> $priority{$idx[$b]} :
                                 -1 :
                                   defined($priority{$idx[$b]}) ?
                                     1 :
                                         $idx[$a] <=> $idx[$b]
                                       } 0 .. $#idx
                      ];
    @urls = @sorted;
    undef(@sorted); undef(@idx);

    if ($Opts{HTML}) {
      print('</h3><p><i>Fragments listed are broken. See the table below to know what action to take.</i></p>');

      # Print a summary
      print "<table border=\"1\">\n<tr><td><b>Code</b></td><td><b>Occurrences</b></td><td><b>What to do</b></td></tr>\n";
      foreach my $code (sort(keys(%code_summary))) {
        printf('<tr%s>', &bgcolor($code));
        printf('<td><a href="#d%scode_%s">%s</a></td>',
               $doc_count, $code, $code);
        printf('<td>%s</td>', $code_summary{$code});
        printf('<td>%s</td>', $todo{$code});
        print "</tr>\n";
      }
      print "</table>\n";
    } else {
      print(':');
    }
    &show_link_report($links, $results, $broken, $redirects,
                      \@urls, 1, \%todo);
  }

  # Show directory redirects
  if ($Opts{Dir_Redirects} && ($#dir_redirect_urls > -1)) {
    print('<h3>') if $Opts{HTML};
    print("\nList of directory redirects");
    print("</h3>\n<p>The links below are not broken, but the document does not use the exact URL.</p>") if $Opts{HTML};
    &show_link_report($links, $results, $broken, $redirects,
                      \@dir_redirect_urls);
  }
}

###############################################################################

################
# Global stats #
################

sub global_stats ()
{
  my $stop = &get_timestamp();
  my $n_docs =
    ($doc_count <= $Opts{Max_Documents}) ? $doc_count : $Opts{Max_Documents};
  return sprintf('Checked %d document%s in %s seconds.',
                 $n_docs,
                 ($n_docs == 1) ? '' : 's',
                 &time_diff($timestamp, $stop));
}

##################
# HTML interface #
##################

sub html_header ($;$$)
{
  my ($uri, $doform, $cookie) = @_;

  $uri = &encode($uri);
  my $title = ' Link Checker' . ($uri eq '' ? '' : ': ' . $uri);

  # mod_perl 1.99_05 doesn't seem to like if the "\n\n" isn't in the same
  # print() statement as the last header...

  my $headers = '';
  if (! $Opts{Command_Line}) {
    $headers .= "Cache-Control: no-cache\nPragma: no-cache\n" if $doform;
    $headers .= "Content-Type: text/html; charset=iso-8859-1\n";
    $headers .= "Content-Script-Type: application/x-javascript\n";
    $headers .= "Set-Cookie: $cookie\n" if $cookie;
    $headers .= "Content-Language: en\n\n";
  }

  my $script = my $onload = '';
  if ($doform) {
    $script = "
<script type=\"application/x-javascript\">
function uriOk()
{
  var v = document.forms[0].uri.value;
  if (v.length > 0) {
    if (v.search) return (v.search(/\\S/) != -1);
    return true;
  }
  return false;
}
</script>";
   $onload = ' onload="document.forms[0].uri.focus()"';
  }

  print $headers, $DocType, "
<html lang=\"en\">
<head>
<title>W3C", $title, "</title>
<style type=\"text/css\">
body, address {
  font-family: sans-serif;
  color: black;
  background: white;
}
pre, code, tt {
  font-family: monospace;
}
img {
  color: white;
  border: none;
  vertical-align: middle;
}
fieldset {
  padding-left: 1em;
  background-color: #eee;
}
h1 a {
  color: black;
}
h1 {
  color: #053188;
}
h1#title {
  background-color: #eee;
  border-bottom: 1px solid black;
  padding: .25em;
}
address {
  padding: 1ex;
  border-top: 1px solid black;
  background-color: #eee;
  clear: right;
}
address img {
  float: right;
  width: 88px;
}
a:hover {
  background-color: #eee#;
}
a:visited {
  color: purple;
}
.report {
  width: 100%;
}
dt.report {
  font-weight: bold;
}
.unauthorized {
  background-color: aqua;
}
.redirect {
  background-color: yellow;
}
.broken {
  background-color: red;
}
.multiple {
  background-color: fuchsia;
}
</style>", $script, "
</head>
<body", $onload, ">
<h1 id=\"title\"><a href=\"http://www.w3.org/\" title=\"W3C\"><img alt=\"W3C\" id=\"logo\" src=\"http://www.w3.org/Icons/w3c_home\" height=\"48\" width=\"72\"></a> ", $title, "</h1>\n\n";
}

sub bgcolor ($)
{
  my ($code) = @_;
  my $class;
  my $r = HTTP::Response->new($code);
  if ($r->is_success()) {
    return '';
  } elsif ($code == 300) {
    $class = 'multiple';
  } elsif ($code == 401) {
    $class = 'unauthorized';
  } elsif ($r->is_redirect()) {
    $class = 'redirect';
  } elsif ($r->is_error()) {
    $class = 'broken';
  } else {
    $class = 'broken';
  }
  return(' class="'.$class.'"');
}

sub show_url ($;$)
{
  my ($url, $fragment) = @_;
  $url .= '#' . $fragment if defined($fragment);
  return sprintf('<a href="%s">%s</a>',
                 $url, &encode(defined($fragment) ? $fragment : $url));
}

sub html_footer ()
{
  printf("<p>%s</p>\n", &global_stats()) if ($doc_count > 0 && !$Opts{Quiet});

  print "
<address>
$PROGRAM $REVISION,
by <a href=\"http://www.w3.org/People/Hugo/\">Hugo Haas</a> and others.<br>
Please send bug reports, suggestions and comments to the
<a href=\"mailto:www-validator\@w3.org?subject=checklink%3A%20\">www-validator
mailing list</a>
(<a href=\"http://lists.w3.org/Archives/Public/www-validator/\">archives</a>).
<br>
Check out the <a href=\"docs/checklink.html\">documentation</a>.
Download the
<a href=\"http://dev.w3.org/cvsweb/~checkout~/validator/httpd/cgi-bin/checklink.pl?rev=$CVS_VERSION&amp;content-type=text/plain\">source code</a> from
<a href=\"http://dev.w3.org/cvsweb/validator/httpd/cgi-bin/checklink.pl\">CVS</a>.
</address>
</body>
</html>
";
}

sub file_uri ($)
{
  my ($uri) = @_;
  &html_header($uri);
  print "<h2>Forbidden</h2>
<p>You cannot check such a URI (<code>$uri</code>).</p>
";
  &html_footer();
  exit;
}

sub print_form ($)
{
  my ($q) = @_;

  my $chk = ' checked="checked"';
  $q->param('hide_type', 'all') unless $q->param('hide_type');

  my $sum = $q->param('summary')              ? $chk : '';
  my $red = $q->param('hide_redirects')       ? $chk : '';
  my $all = ($q->param('hide_type') ne 'dir') ? $chk : '';
  my $dir = $all                              ? ''   : $chk;
  my $acc = $q->param('no_accept_language')   ? $chk : '';
  my $rec = $q->param('recursive')            ? $chk : '';
  my $dep = &encode($q->param('depth')              || '');

  my $cookie_options = '';
  if ($q->cookie()) {
    $cookie_options = "
    <label for=\"cookie1\"><input type=\"radio\" id=\"cookie1\" name=\"cookie\" value=\"nochanges\" checked=\"checked\"> Don't modify saved options</label>
    <label for=\"cookie2\"><input type=\"radio\" id=\"cookie2\" name=\"cookie\" value=\"set\"> Save these options</label>
    <label for=\"cookie3\"><input type=\"radio\" id=\"cookie3\" name=\"cookie\" value=\"clear\"> Clear saved options</label>";
  } else {
    $cookie_options = "
    <label for=\"cookie\"><input type=\"checkbox\" id=\"cookie\" name=\"cookie\" value=\"set\"> Save options in a <a href=\"http://www.w3.org/Protocols/rfc2109/rfc2109\">cookie</a></label>";
  }

  print "<form action=\"", $q->self_url(), "\" method=\"get\" onsubmit=\"return uriOk()\">
<p><label for=\"uri\">Enter the address (<a href=\"http://www.w3.org/Addressing/#terms\">URL</a>)
of a document that you would like to check:</label></p>
<p><input type=\"text\" size=\"50\" id=\"uri\" name=\"uri\" value=\"\"></p>
<fieldset>
  <legend>Options</legend>
  <p>
    <label for=\"summary\"><input type=\"checkbox\" id=\"summary\" name=\"summary\" value=\"on\"", $sum, "> Summary only</label>
    <br>
    <label for=\"hide_redirects\"><input type=\"checkbox\" id=\"hide_redirects\" name=\"hide_redirects\" value=\"on\"", $red, "> Hide <a href=\"http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html#sec10.3\">redirects</a>:</label>
    <label><input type=\"radio\" name=\"hide_type\" value=\"all\"", $all, "> all</label>
    <label><input type=\"radio\" name=\"hide_type\" value=\"dir\"", $dir, "> for directories only</label>
    <br>
    <label for=\"no_accept_language\"><input type=\"checkbox\" id=\"no_accept_language\" name=\"no_accept_language\" value=\"on\"", $acc, "> Don't send <tt><a href=\"http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.4\">Accept-Language</a></tt> headers</label>
    <br>
    <label title=\"Check linked documents recursively (maximum: ", $Opts{Max_Documents}, " documents; sleeping ", $Opts{Sleep_Time}, " seconds between each document)\" for=\"recursive\"><input type=\"checkbox\" id=\"recursive\" name=\"recursive\" value=\"on\"", $rec, "> Check linked documents recursively</label>,
    <label title=\"Depth of the recursion (-1 is the default and means unlimited)\" for=\"depth\">recursion depth: <input type=\"text\" size=\"3\" maxlength=\"3\" id=\"depth\" name=\"depth\" value=\"", $dep, "\"></label>
    <br><br>", $cookie_options, "
  </p>
</fieldset>
<p><input type=\"submit\" name=\"check\" value=\"Check\"></p>
</form>
";
}

sub encode (@)
{
  return $Opts{HTML} ? HTML::Entities::encode(@_) : @_;
}

sub hprintf (@)
{
  if (! $Opts{HTML}) {
    printf(@_);
  } else {
    print HTML::Entities::encode(sprintf($_[0], @_[1..@_-1]));
  }
}