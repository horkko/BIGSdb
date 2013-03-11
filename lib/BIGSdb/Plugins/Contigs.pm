#Contigs.pm - Contig export and analysis plugin for BIGSdb
#Written by Keith Jolley
#Copyright (c) 2013, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::Plugins::Contigs;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Plugin);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use Error qw(:try);
use List::MoreUtils qw(any none);
use constant MAX_ISOLATES => 1000;
use BIGSdb::Page qw(SEQ_METHODS);

sub get_attributes {
	my %att = (
		name        => 'Contig export',
		author      => 'Keith Jolley',
		affiliation => 'University of Oxford, UK',
		email       => 'keith.jolley@zoo.ox.ac.uk',
		description => 'Analyse and export contigs selected from query results',
		category    => 'Export',
		buttontext  => 'Contigs',
		menutext    => 'Contigs',
		module      => 'Contigs',
		version     => '1.0.0',
		dbtype      => 'isolates',
		section     => 'export,postquery',
		input       => 'query',
		help        => 'tooltips',
		order       => 20,
		system_flag => 'ContigExport'
	);
	return \%att;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { general => 1, main_display => 0, isolate_display => 0, analysis => 1, query_field => 1 };
	return;
}

sub _download_contigs {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $isolate_id = $q->param('isolate_id');
	if ( !defined $isolate_id || !BIGSdb::Utils::is_int($isolate_id) ) {
		say "Invalid isolate id passed.";
	}
	my $pc_untagged = $q->param('pc_untagged') // 0;
	if ( !defined $pc_untagged || !BIGSdb::Utils::is_int($pc_untagged) ) {
		say "Invalid percentage tagged threshold value passed.";
		return;
	}
	$pc_untagged = $1 if $pc_untagged =~ /^(\d+)$/;    #untaint
	my $data = $self->_calculate( $isolate_id, { pc_untagged => $pc_untagged, get_contigs => 1 } );
	my $export_seq = $q->param('match') ? $data->{'match_seq'} : $data->{'non_match_seq'};
	if ( !@$export_seq ) {
		say "No sequences matching selected criteria.";
		return;
	}
	foreach (@$export_seq) {
		say ">$_->{'seqbin_id'}";
		my $cleaned_seq = BIGSdb::Utils::break_line( $_->{'sequence'}, 60 ) || '';
		say $cleaned_seq;
	}
	return;
}

sub run {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $q->param('format') eq 'text' ) {
		$self->_download_contigs;
		return;
	}
	say "<h1>Contig analysis and export</h1>";
	$self->_print_interface;
	if ( $q->param('submit') ) {
		my @ids = $q->param('isolate_id');
		my $filtered_ids = $self->filter_ids_by_project( \@ids, $q->param('project_list') );
		if ( !@$filtered_ids ) {
			say "<div class=\"box\" id=\"statusbad\"><p>You must include one or more isolates. Make sure your "
			  . "selected isolates haven't been filtered to none by selecting a project.</p></div>";
			return;
		} elsif ( @$filtered_ids > MAX_ISOLATES ) {
			my $max_isolates =
			  ( $self->{'system'}->{'contig_analysis_limit'} && BIGSdb::Utils::is_int( $self->{'system'}->{'contig_analysis_limit'} ) )
			  ? $self->{'system'}->{'contig_analysis_limit'}
			  : MAX_ISOLATES;
			say "<div class=\"box\" id=\"statusbad\"><p>Contig analysis is limited to $max_isolates isolates.  You have "
			  . "selected "
			  . @$filtered_ids
			  . ".</p></div>";
			return;
		}
		$self->_run_analysis($filtered_ids);
	}
	return;
}

sub _run_analysis {
	my ( $self, $filtered_ids ) = @_;
	my $q = $self->{'cgi'};
	say "<div class=\"box\" id=\"resultstable\">";
	my $pc_untagged = $q->param('pc_untagged');
	$pc_untagged = 0 if !defined $pc_untagged || !BIGSdb::Utils::is_int($pc_untagged);
	my $title = "Contigs with >=$pc_untagged\% sequence length untagged";
	print << "HTML";
<h2>$title</h2>
<table class="tablesorter" id="sortTable"><thead><tr><th rowspan="2">id</th><th rowspan="2">
$self->{'system'}->{'labelfield'}</th><th rowspan="2">contigs</th><th colspan="2" class="{sorter: false}">
matching contigs</th><th colspan="2" class="{sorter: false}">non-matching contigs</th></tr>\n<tr><th>count</th>
<th class="{sorter: false}">download</th><th>count</th><th class="{sorter: false}">download</th></tr></thead><tbody>
HTML
	my $filebuffer = << "TEXTFILE";
$title:

id\t$self->{'system'}->{'labelfield'}\tcontigs\tmatching contigs\tnon-matching contigs
TEXTFILE
	my $label_field = $self->{'system'}->{'labelfield'};
	my $isolate_sql = $self->{'db'}->prepare("SELECT $label_field FROM $self->{'system'}->{'view'} WHERE id=?");
	my $td          = 1;
	local $| = 1;

	foreach my $isolate_id (@$filtered_ids) {
		my $isolate_values = $self->{'datastore'}->get_isolate_field_values($isolate_id);
		my $isolate_name   = $isolate_values->{ lc($label_field) };
		say "<tr class=\"td$td\"><td><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=info&amp;"
		  . "id=$isolate_id\">$isolate_id</a></td><td>$isolate_name</td>";
		my $results = $self->_calculate( $isolate_id, { pc_untagged => $pc_untagged } );
		say "<td>$results->{'total'}</td><td>$results->{'pc_untagged'}</td>";
		my @attributes;
		push @attributes, "pc_untagged=$pc_untagged";
		push @attributes, 'min_length=' . ( $q->param('min_length_list') // 0 );
		push @attributes, 'seq_method=' . $q->param('seq_method_list') if $q->param('seq_method_list');
		push @attributes, 'experiment=' . $q->param('experiment_list') if $q->param('experiment_list');
		push @attributes, 'header=' . $q->param('header_list') // 1;
		local $" = '&amp;';
		say $results->{'pc_untagged'}
		  ? "<td><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=plugin&amp;"
		  . "name=Contigs&amp;format=text&amp;isolate_id=$isolate_id&amp;match=1&amp;@attributes\""
		  . " class=\"downloadbutton\">&darr;</a></td>"
		  : "<td />";
		my $non_match = $results->{'total'} - $results->{'pc_untagged'};
		say $non_match
		  ? "<td>$non_match</td><td><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=plugin&amp;name=Contigs&amp;"
		  . "format=text&amp;isolate_id=$isolate_id&amp;match=0&amp;@attributes\" class=\"downloadbutton\">&darr;</a></td>"
		  : "<td>$non_match</td><td />";
		say "</tr>";
		$filebuffer .= "$isolate_id\t$isolate_name\t$results->{'total'}\t$results->{'pc_untagged'}\t$non_match\n";
		$td = $td == 1 ? 2 : 1;

		if ( $ENV{'MOD_PERL'} ) {
			$self->{'mod_perl_request'}->rflush;
			return if $self->{'mod_perl_request'}->connection->aborted;
		}
	}
	say "</tbody></table>";
	my $prefix   = BIGSdb::Utils::get_random();
	my $filename = "$self->{'config'}->{'tmp_dir'}/$prefix.txt";
	open( my $fh, '>', $filename ) || $logger->error("Can't open $filename for writing");
	say $fh $filebuffer;
	close $fh;
	print "<p style=\"margin-top:1em\"><a href=\"/tmp/$prefix.txt\">Tab-delimited text format</a></p>";
	say "</div>";
	return;
}

sub _calculate {
	my ( $self, $isolate_id, $options ) = @_;
	my $q        = $self->{'cgi'};
	my $add_seq  = $options->{'get_contigs'} ? ',sequence' : '';
	my $qry      = "SELECT id,length(sequence) AS seq_length,original_designation$add_seq FROM sequence_bin WHERE isolate_id=?";
	my @criteria = ($isolate_id);
	my $method   = $q->param('seq_method_list') // $q->param('seq_method');
	if ($method) {
		if ( !any { $_ eq $method } SEQ_METHODS ) {
			$logger->error("Invalid method $method");
			return;
		}
		$qry .= " AND method=?";
		push @criteria, $method;
	}
	my $experiment = $q->param('experiment_list') // $q->param('experiment');
	if ($experiment) {
		if ( !BIGSdb::Utils::is_int($experiment) ) {
			$logger->error("Invalid experiment $experiment");
			return;
		}
		$qry .= " AND id IN (SELECT seqbin_id FROM experiment_sequences WHERE experiment_id=?)";
		push @criteria, $experiment;
	}
	$qry .= " ORDER BY id";
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(@criteria); };
	my ( $total, $pc_untagged ) = ( 0, 0 );
	my $tagged_sql = $self->{'db'}->prepare("SELECT sum(abs(end_pos-start_pos)) FROM allele_sequences WHERE seqbin_id=?");
	my ( @match_seq, @non_match_seq );
	while ( my ( $seqbin_id, $seq_length, $orig_designation, $seq ) = $sql->fetchrow_array ) {
		my $min_length = $q->param('min_length_list') // $q->param('min_length');
		next if ( $min_length && BIGSdb::Utils::is_int($min_length) && $seq_length < $min_length );
		my $match = 1;
		$total++;
		eval { $tagged_sql->execute($seqbin_id) };
		$logger->error($@) if $@;
		my ($tagged_length) = $tagged_sql->fetchrow_array // 0;
		$tagged_length = $seq_length if $tagged_length > $seq_length;

		if ( ( ( $seq_length - $tagged_length ) * 100 / $seq_length ) >= $options->{'pc_untagged'} ) {
			$pc_untagged++;
		} else {
			$match = 0;
		}
		if ( $options->{'get_contigs'} ) {
			my $header = ( $q->param('header') // 1 ) == 1 ? ( $orig_designation || $seqbin_id ) : $seqbin_id;
			if ($match) {
				push @match_seq, { seqbin_id => $header, sequence => $seq };
			} else {
				push @non_match_seq, { seqbin_id => $header, sequence => $seq };
			}
		}
	}
	my %values = ( total => $total, pc_untagged => $pc_untagged, match_seq => \@match_seq, non_match_seq => \@non_match_seq );
	return \%values;
}

sub _print_interface {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $view       = $self->{'system'}->{'view'};
	my $query_file = $q->param('query_file');
	my $qry_ref    = $self->get_query($query_file);
	my $selected_ids = defined $query_file ? $self->get_ids_from_query($qry_ref) : [];
	my $seqbin_values = $self->{'datastore'}->run_simple_query("SELECT EXISTS(SELECT id FROM sequence_bin)");
	if ( !$seqbin_values->[0] ) {
		say "<div class=\"box\" id=\"statusbad\"><p>There are no sequences in the sequence bin.</p></div>";
		return;
	}
	print <<"HTML";
<div class="box" id="queryform">
<p>Please select the required isolate ids from which contigs are associated - use Ctrl or Shift to make multiple 
selections.  Please note that the total length of tagged sequence is calculated by adding up the length of all loci tagged
within the contig - if these loci overlap then the total tagged length will be reported as being longer than it really is 
but it won't exceed the length of the contig.</p>
HTML
	say $q->start_form;
	say "<div class=\"scrollable\">";
	$self->print_seqbin_isolate_fieldset( { selected_ids => $selected_ids } );
	$self->_print_options_fieldset;
	$self->print_sequence_filter_fieldset( { min_length => 1 } );
	say "<div style=\"clear:both\"><span style=\"float:left\"><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;"
	  . "page=plugin&amp;name=Contigs\" class=\"resetbutton\">Reset</a></span><span style=\"float:right;padding-right:5%\">";
	say $q->submit( -name => 'submit', -label => 'Submit', -class => 'submit' );
	say "</span></div>";
	say $q->hidden($_) foreach qw (page name db);
	say "</div>";
	say $q->end_form;
	say "</div>";
	return;
}

sub _print_options_fieldset {
	my ($self)    = @_;
	my $q         = $self->{'cgi'};
	my @pc_values = ( 0 .. 100 );
	say "<fieldset style=\"float:left\">\n<legend>Options</legend>";
	say "<ul>";
	say "<li><label for=\"pc_untagged\">Identify contigs with >= </label>";
	say $q->popup_menu( -name => 'pc_untagged', -id => 'pc_untagged', -values => \@pc_values );
	say "% of sequence untagged</li>";
	say "<li><label for=\"header_list\">FASTA header line: </label>";
	say $q->popup_menu(
		-name   => 'header_list',
		-id     => 'header_list',
		-values => [qw (1 2)],
		-labels => { 1 => 'original designation', 2 => 'seqbin id' }
	);
	say " <a class=\"tooltip\" title=\"FASTA header line - Seqbin id will be used if the original designation has not been stored.\">"
	  . "&nbsp;<i>i</i>&nbsp;</a>";
	say "</li></ul>";
	say "</fieldset>";
	return;
}
1;