package FixMyStreet::App::Controller::Admin::ExorDefects;
use Moose;
use namespace::autoclean;

use Text::CSV;
use DateTime;
use mySociety::Random qw(random_bytes);

BEGIN { extends 'Catalyst::Controller'; }


sub begin : Private {
    my ( $self, $c ) = @_;

    $c->forward('/admin/begin');
}

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    my @inspectors = $c->cobrand->users->search({
        'user_body_permissions.permission_type' => 'report_inspect'
    }, {
            join => 'user_body_permissions',
            distinct => 1,
        }
    )->all;
    $c->stash->{inspectors} = \@inspectors;

    # Default start/end date is today
    my $now = DateTime->now( time_zone => 
        FixMyStreet->time_zone || FixMyStreet->local_time_zone );
    $c->stash->{start_date} = $now;
    $c->stash->{end_date} = $now;

}

sub download : Path('download') : Args(0) {
    my ( $self, $c ) = @_;

    if ( !$c->cobrand->can('exor_rdi_link_id') ) {
        # This only works on the Oxfordshire cobrand currently.
        $c->detach( '/page_error_404_not_found', [] );
    }

    my $parser = DateTime::Format::Strptime->new( pattern => '%d/%m/%Y' );
    my $start_date = $parser-> parse_datetime ( $c->get_param('start_date') );
    my $end_date = $parser-> parse_datetime ( $c->get_param('end_date') ) ;
    my $one_day = DateTime::Duration->new( days => 1 );

    my %params = (
        'admin_log_entries.action' => 'inspected',
        'admin_log_entries.whenedited' => { '>=', $start_date },
        'admin_log_entries.whenedited' => { '<=', $end_date + $one_day },
        # state => [ 'action scheduled' ],
    );

    my $initials = "XX";
    if ( $c->get_param('user_id') ) {
        my $uid = $c->get_param('user_id');
        $params{'admin_log_entries.user_id'} = $uid;
        my $user = $c->model('DB::User')->find( { id => $uid } );
        $initials = $user->initials if $user;
    }

    my $problems = $c->cobrand->problems->search(
        \%params,
        {
            join => 'admin_log_entries',
            distinct => 1,
        }
    );

    my $csv = Text::CSV->new({ binary => 1, eol => "" });

    my $p_count = 0;
    my $link_id = $c->cobrand->exor_rdi_link_id;

    # RDI first line is always the same
    $csv->combine("1", "1.8", "1.0.0.0", "ENHN", "");
    my @body = ($csv->string);

    # Let's just group all defects into a single inspection/sequence for now
    $csv->combine(
        "G", # start of an area/sequence
        $link_id, # area/link id, fixed value for our purposes
        "","", # must be empty
        $initials, # inspector initials
        $start_date->strftime("%y%m%d"), # date of inspection yymmdd
        "0700", # time of inspection hhmm, set to static value for now
        "D", # inspection variant, should always be D
        "INS", # inspection type, always INS
        "N", # Area of the county - north (N) or south (S)
        "", "", "", "" # empty fields
    );
    push @body, $csv->string;

    $csv->combine(
        "H", # initial inspection type
        "MC" # minor carriageway (changes depending on activity code)
    );
    push @body, $csv->string;

    my $i = 1;
    while ( my $report = $problems->next ) {
        my ($eastings, $northings) = $report->local_coords;
        my $description = sprintf("%s %s", $report->external_id || "", $report->get_extra_metadata('detailed_information') || "");
        $csv->combine(
            "I", # beginning of defect record
            "MC", # activity code - minor carriageway, also FC (footway)
            "", # empty field, can also be A (seen on MC) or B (seen on FC)
            sprintf("%03d", $i++), # randomised sequence number
            "${eastings}E ${northings}N", # defect location field, which we don't capture from inspectors
            $report->inspection_log_entry->whenedited->strftime("%H%M"), # defect time raised
            "","","","","","","", # empty fields
            $report->get_extra_metadata('traffic_information') ? 'TM required' : 'TM none', # further description
            $description, # defect description
        );
        push @body, $csv->string;

        $csv->combine(
            "J", # georeferencing record
            $report->get_extra_metadata('defect_type') || 'SFP2', # defect type - SFP2: sweep and fill <1m2, POT2 also seen
            $report->response_priority ?
                $report->response_priority->external_id :
                "2", # priority of defect
            "","", # empty fields
            $eastings, # eastings
            $northings, # northings
            "","","","","" # empty fields
        );
        push @body, $csv->string;

        $csv->combine(
            "M", # bill of quantities record
            "resolve", # permanent repair
            "","", # empty fields
            "/CMC", # /C + activity code
            "", "" # empty fields
        );
        push @body, $csv->string;
    }

    # end this group of defects with a P record
    $csv->combine(
        "P", # end of area/sequence
        0, # always 0
        999999, # charging code, always 999999 in OCC
    );
    push @body, $csv->string;
    $p_count++;

    # end the RDI file with an X record
    my $record_count = $problems->count;
    $csv->combine(
        "X", # end of inspection record
        $p_count,
        $p_count,
        $record_count, # number of I records
        $record_count, # number of J records
        0, 0, 0, # always zero
        $record_count, # number of M records
        0, # always zero
        $p_count,
        0, 0, 0 # error counts, always zero
    );
    push @body, $csv->string;

    my $start = $start_date->strftime("%Y%m%d");
    my $end = $end_date->strftime("%Y%m%d");
    my $filename = sprintf("exor_defects-%s-%s-%s.rdi", $start, $end, $initials);
    $c->res->content_type('text/csv; charset=utf-8');
    $c->res->header('content-disposition' => "attachment; filename=$filename");
    # The RDI format is very weird CSV - each line must be wrapped in
    # double quotes.
    $c->res->body( join "", map { "\"$_\"\r\n" } @body );
}

1;