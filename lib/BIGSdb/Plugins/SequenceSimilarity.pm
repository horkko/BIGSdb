#SequenceSimilarity.pm - Plugin for BIGSdb
#This requires the SequenceComparison plugin
#Written by Keith Jolley
#Copyright (c) 2010-2015, University of Oxford
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
package BIGSdb::Plugins::SequenceSimilarity;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Plugin);
use BIGSdb::Constants qw(:interface);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use Error qw(:try);
use Apache2::Connection ();

sub get_attributes {
	my ($self) = @_;
	my %att = (
		name             => 'Sequence Similarity',
		author           => 'Keith Jolley',
		affiliation      => 'University of Oxford, UK',
		email            => 'keith.jolley@zoo.ox.ac.uk',
		description      => 'Find sequences most similar to selected allele',
		menu_description => 'find sequences most similar to selected allele.',
		category         => 'Analysis',
		menutext         => 'Sequence similarity',
		module           => 'SequenceSimilarity',
		url              => "$self->{'config'}->{'doclink'}/data_query.html#sequence-similarity",
		version          => '1.0.4',
		dbtype           => 'sequences',
		seqdb_type       => 'sequences',
		section          => 'analysis',
		requires         => '',
		order            => 10
	);
	return \%att;
}

sub run {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	my $locus = $q->param('locus') || '';
	$locus =~ s/^cn_//x;
	my $allele = $q->param('allele');
	my $desc   = $self->get_db_description;
	say qq(<h1>Find most similar alleles - $desc</h1>);
	my $set_id = $self->get_set_id;
	my ( $display_loci, $cleaned ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id } );

	if ( !@$display_loci ) {
		say q(<div class="box" id="statusbad"><p>No loci have been defined for this database.</p></div>);
		return;
	}
	say q(<div class="box" id="queryform">);
	say q(<p>This page allows you to find the most similar sequences to a selected allele using BLAST.</p>);
	my $num_results = 10;
	if ( defined $q->param('num_results') && $q->param('num_results') =~ /(\d+)/x ) {
		$num_results = $1;
	}
	say $q->start_form;
	say $q->hidden($_) foreach qw (db page name);
	say q(<fieldset style="float:left"><legend>Select parameters</legend>);
	say q(<ul><li><label for="locus" class="parameter">Locus: </label>);
	say $q->popup_menu( -name => 'locus', -id => 'locus', -values => $display_loci, -labels => $cleaned );
	say q(</li><li><label for="allele" class="parameter">Allele: </label>);
	say $q->textfield( -name => 'allele', -id => 'allele', -size => 4 );
	say q(</li><li><label for="num_results" class="parameter">Number of results:</label>);
	say $q->popup_menu(
		-name    => 'num_results',
		-id      => 'num_results',
		-values  => [ 5, 10, 25, 50, 100, 200 ],
		-default => $num_results
	);
	say q(</li></ul></fieldset>);
	$self->print_action_fieldset( { name => 'SequenceSimilarity' } );
	say $q->end_form;
	say q(</div>);
	return if !$locus || !defined $allele || $allele eq q();

	if ( !$self->{'datastore'}->is_locus($locus) ) {
		say q(<div class="box" id="statusbad"><p>Invalid locus entered.</p></div>);
		return;
	}
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	if ( $locus_info->{'allele_id_format'} eq 'integer' && !BIGSdb::Utils::is_int($allele) ) {
		say q(<div class="box" id="statusbad"><p>Allele must be an integer.</p></div>);
		return;
	}
	my ($valid) =
	  $self->{'datastore'}
	  ->run_query( q(SELECT EXISTS(SELECT * FROM sequences WHERE (locus,allele_id)=(?,?) AND allele_id != '0')),
		[ $locus, $allele ] );
	if ( !$valid ) {
		say qq(<div class="box" id="statusbad"><p>Allele $locus-$allele does not exist.</p></div>);
		return;
	}
	my $cleanlocus = $self->clean_locus($locus);
	my $seq_ref = $self->{'datastore'}->get_sequence( $locus, $allele );
	my ( $blast_file, undef ) = $self->{'datastore'}->run_blast(
		{
			locus       => $locus,
			seq_ref     => $seq_ref,
			qry_type    => $locus_info->{'data_type'},
			num_results => $num_results + 1,
			set_id      => $set_id
		}
	);
	my $matches = $self->_parse_blast_partial($blast_file);
	say q(<div class="box" id="resultsheader">);
	say qq(<h2>$cleanlocus-$allele</h2>);
	if ( ref $matches eq 'ARRAY' && @$matches > 0 ) {
		say q(<table class="resultstable"><tr><th>Allele</th><th>% Identity</th><th>Mismatches</th>)
		  . q(<th>Gaps</th><th>Alignment</th><th>Compare</th></tr>);
		my $td = 1;
		foreach my $match (@$matches) {
			next if $match->{'allele'} eq $allele;
			my $length = length $$seq_ref;
			say qq(<tr class="td$td"><td>$cleanlocus: $match->{'allele'}</td><td>$match->{'identity'}</td>)
			  . qq(<td>$match->{'mismatches'}</td><td>$match->{'gaps'}</td><td>$match->{'alignment'}/$length)
			  . q(</td><td>);
			say $q->start_form;
			$q->param( allele1 => $allele );
			$q->param( allele2 => $match->{'allele'} );
			$q->param( name    => 'SequenceComparison' );
			$q->param( sent    => 1 );
			say $q->hidden($_) foreach qw (db page name locus allele1 allele2 sent);
			my $compare = COMPARE;
			say qq(<button type="submit" name="compare:$match->{'allele'}" class="smallbutton">$compare</button>);
			say $q->end_form;
			say q(</td></tr>);
			$td = $td == 1 ? 2 : 1;
		}
		say q(</table>);
	} else {
		say q(<p>No similar alleles found.</p>);
	}
	unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	say q(</div>);
	return;
}

sub _parse_blast_partial {

	#return best match
	my ( $self, $blast_file ) = @_;
	my $full_path = "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	open( my $blast_fh, '<', $full_path )
	  || ( $logger->error("Can't open BLAST output file $full_path. $!"), return \$; );
	my @matches;
	my %allele_matched;
	while ( my $line = <$blast_fh> ) {
		next if !$line || $line =~ /^\#/x;
		my $match;
		my @record = split /\s+/x, $line;
		next if $allele_matched{ $record[1] };    #sometimes BLAST will display two alignments for a sequence
		@$match{qw(allele identity alignment mismatches gaps)} = @record[ 1 .. 5 ];
		push @matches, $match;
		$allele_matched{ $record[1] } = 1;
	}
	close $blast_fh;
	return \@matches;
}
1;
