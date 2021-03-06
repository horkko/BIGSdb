#Written by Keith Jolley
#Copyright (c) 2010-2016, University of Oxford
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
package BIGSdb::SequenceQueryPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Page);
use Log::Log4perl qw(get_logger);
use List::MoreUtils qw(any none);
use BIGSdb::BIGSException;
use BIGSdb::Constants qw(:interface);
use Bio::DB::GenBank;
use IO::String;
use Bio::SeqIO;
use Error qw(:try);
my $logger = get_logger('BIGSdb.Page');
use constant INF => 9**99;

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return $self->{'cgi'}->param('page') eq 'sequenceQuery'
	  ? qq(Sequence query - $desc)
	  : qq(Batch sequence query - $desc);
}

sub get_help_url {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	return if $q->param('page') eq 'batchSequenceQuery';
	return "$self->{'config'}->{'doclink'}/data_query.html#querying-sequences-to-determine-allele-identity";
}

sub get_javascript {
	my $buffer = << "END";
\$(function () {
	\$('a[data-rel=ajax]').click(function(){
  		\$(this).attr('href', function(){
  			if (this.href.match(/javascript.loadContent/)){
  				return;
  			};
    		return(this.href.replace(/(.*)/, "javascript:loadContent\('\$1\'\)"));
    	});
  	});
});

function loadContent(url) {
	\$("#alignment").html('<img src=\"/javascript/themes/default/throbber.gif\" /> Loading ...').load(url);
	\$("#alignment_link").hide();
}

END
	return $buffer;
}

sub _print_interface {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	my $locus = $q->param('locus') // 0;
	$locus =~ s/%27/'/gx if $locus;    #Web-escaped locus
	$q->param( locus => $locus );
	my $page   = $q->param('page');
	my $desc   = $self->get_db_description;
	my $set_id = $self->get_set_id;
	if ( $locus && $q->param('simple') ) {

		if ( $q->param('locus') =~ /^SCHEME_(\d+)$/x ) {
			my $scheme_info = $self->{'datastore'}->get_scheme_info($1);
			$desc = $scheme_info->{'name'};
		} else {
			$desc = $q->param('locus');
		}
	}
	say $page eq 'sequenceQuery' ? qq(<h1>Sequence query - $desc</h1>) : qq(<h1>Batch sequence query - $desc</h1>);
	say q(<div class="box" id="queryform">);
	say q(<p>Please paste in your sequence)
	  . ( $page eq 'batchSequenceQuery' ? 's' : '' )
	  . q( to query against the database. );
	if ( !$q->param('simple') ) {
		say q(Query sequences will be checked first for an exact match against the chosen (or all) loci - )
		  . q(they do not need to be trimmed. The nearest partial matches will be identified if an exact )
		  . q(match is not found. You can query using either DNA or peptide sequences. )
		  . q( <a class="tooltip" title="Query sequence - Your query sequence is assumed to be DNA if it contains )
		  . q(90% or more G,A,T,C or N characters."><span class="fa fa-info-circle"></span></a>);
	}
	say q(</p>);
	say $q->start_form;
	say q(<div class="scrollable">);
	if ( !$q->param('simple') ) {
		say q(<fieldset><legend>Please select locus/scheme</legend>);
		my ( $display_loci, $cleaned ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id } );
		my $scheme_list = $self->get_scheme_data;
		my %order;
		my @schemes_and_groups;
		foreach my $scheme ( reverse @$scheme_list ) {
			my $value = "SCHEME_$scheme->{'id'}";
			push @schemes_and_groups, $value;
			$order{$value} = $scheme->{'display_order'} if $scheme->{'display_order'};
			$cleaned->{$value} = $scheme->{'name'};
		}
		my $group_list = $self->{'datastore'}->get_group_list( { seq_query => 1 } );
		foreach my $group ( reverse @$group_list ) {
			my $group_schemes = $self->{'datastore'}->get_schemes_in_group( $group->{'id'}, { set_id => $set_id } );
			if (@$group_schemes) {
				my $value = "GROUP_$group->{'id'}";
				push @schemes_and_groups, $value;
				$order{$value} = $group->{'display_order'} if $group->{'display_order'};
				$cleaned->{$value} = $group->{'name'};
			}
		}
		@schemes_and_groups =
		  sort { ( $order{$a} // INF ) <=> ( $order{$b} // INF ) || $cleaned->{$a} cmp $cleaned->{$b} }
		  @schemes_and_groups;
		unshift @$display_loci, @schemes_and_groups;
		unshift @$display_loci, 0;
		$cleaned->{0} = 'All loci';
		say $q->popup_menu( -name => 'locus', -values => $display_loci, -labels => $cleaned );
		say q(</fieldset>);
		say q(<fieldset><legend>Order results by</legend>);
		say $q->popup_menu( -name => 'order', -values => [ ( 'locus', 'best match' ) ] );
		say q(</fieldset>);
	} else {
		$q->param( order => 'locus' );
		say $q->hidden($_) foreach qw(locus order simple);
	}
	say q(<div style="clear:both">);
	say q(<fieldset style="float:left"><legend>)
	  . (
		$page eq 'sequenceQuery'
		? q(Enter query sequence (single or multiple contigs up to whole genome in size))
		: q(Enter query sequences (FASTA format))
	  ) . q(</legend>);
	say $q->textarea( -name => 'sequence', -rows => 6, -cols => 70 );
	say q(</fieldset>);
	say q(<fieldset style="float:left"><legend>Alternatively upload FASTA file</legend>);
	say q(Select FASTA file:<br />);
	say $q->filefield( -name => 'fasta_upload', -id => 'fasta_upload' );
	say q(</fieldset>);

	if ( $page eq 'sequenceQuery' && ( $self->{'config'}->{'intranet'} // '' ) ne 'yes' ) {
		say q(<fieldset style="float:left"><legend>or enter Genbank accession</legend>);
		say $q->textfield( -name => 'accession' );
		say q(</fieldset>);
	}
	my $action_args;
	$action_args->{'simple'} = 1       if $q->param('simple');
	$action_args->{'set_id'} = $set_id if $set_id;
	$self->print_action_fieldset($action_args);
	say q(</div></div>);
	say $q->hidden($_) foreach qw (db page word_size);
	say $q->end_form;
	say q(</div>);
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		say q(<div class="box" id="statusbad"><p>This function is not available in isolate databases.</p></div>);
		return;
	}
	my $sequence;
	$self->populate_submission_params;
	if ( $q->param('sequence') ) {
		$sequence = $q->param('sequence');
		$q->delete('sequence') if !$q->param('submission_id');
	}
	$self->_print_interface;
	if ( $q->param('submit') ) {
		if ($sequence) {
			$self->_run_query( \$sequence );
		} elsif ( $q->param('fasta_upload') ) {
			my $upload_file = $self->_upload_fasta_file;
			my $full_path   = "$self->{'config'}->{'secure_tmp_dir'}/$upload_file";
			if ( -e $full_path ) {
				$self->_run_query( BIGSdb::Utils::slurp($full_path) );
				unlink $full_path;
			}
		} elsif ( $q->param('accession') ) {
			try {
				my $acc_seq = $self->_upload_accession;
				if ($acc_seq) {
					$self->_run_query( \$acc_seq );
				}
			}
			catch BIGSdb::DataException with {
				my $err = shift;
				$logger->debug($err);
				if ( $err =~ /INVALID_ACCESSION/x ) {
					say q(<div class="box" id="statusbad"><p>Accession is invalid.</p></div>);
				} elsif ( $err =~ /NO_DATA/x ) {
					say q(<div class="box" id="statusbad"><p>The accession is valid but it )
					  . q(contains no sequence data.</p></div>);
				}
			};
		}
	}
	return;
}

sub _upload_fasta_file {
	my ($self)   = @_;
	my $temp     = BIGSdb::Utils::get_random();
	my $filename = "$self->{'config'}->{'secure_tmp_dir'}/$temp\_upload.fas";
	my $buffer;
	open( my $fh, '>', $filename ) || $logger->error("Could not open $filename for writing.");
	my $fh2 = $self->{'cgi'}->upload('fasta_upload');
	binmode $fh2;
	binmode $fh;
	read( $fh2, $buffer, $self->{'config'}->{'max_upload_size'} );
	print $fh $buffer;
	close $fh;
	return "$temp\_upload.fas";
}

sub _upload_accession {
	my ($self)    = @_;
	my $accession = $self->{'cgi'}->param('accession');
	my $seq_db    = Bio::DB::GenBank->new;
	$seq_db->retrieval_type('tempfile');    #prevent forking resulting in duplicate error message on fail.
	my $sequence;
	try {
		my $seq_obj = $seq_db->get_Seq_by_acc($accession);
		$sequence = $seq_obj->seq;
	}
	catch Bio::Root::Exception with {
		my $err = shift;
		$logger->debug($err);
		throw BIGSdb::DataException('INVALID_ACCESSION');
	};
	if ( !length($sequence) ) {
		throw BIGSdb::DataException('NO_DATA');
	}
	return $sequence;
}

sub _get_word_size {
	my ( $self, $locus ) = @_;
	my $q = $self->{'cgi'};
	my $word_size;
	if ( $q->param('word_size') && $q->param('word_size') =~ /^(\d+)$/x ) {
		$word_size = $1;
	}

	#Use big word size when querying 'all loci' as we're mainly interested in exact matches.
	$word_size //= $locus ? 15 : 30;
	return $word_size;
}

sub _is_distinct_locus_selected {
	my ( $self, $locus ) = @_;
	return 1 if $locus && $locus !~ /SCHEME_\d+/x && $locus !~ /GROUP_\d+/x;
	return;
}

sub _parse_exact_matches {
	my ( $self, $seq_ref, $locus, $blast_file ) = @_;
	if ( ( $self->{'system'}->{'diploid'} // '' ) eq 'yes' ) {
		return $self->parse_blast_diploid_exact( $seq_ref, $locus, $blast_file );
	} else {
		return $self->parse_blast_exact( $locus, $blast_file );
	}
}

sub _process_query_seq {
	my ( $self, $seq_ref ) = @_;
	my $page = $self->{'cgi'}->param('page');

	#Allows BLAST of multiple contigs
	$self->remove_all_identifier_lines($seq_ref) if $page eq 'sequenceQuery';
	my $sequence = $$seq_ref;

	#Add identifier line if one missing since newer versions of BioPerl check
	if ( $sequence !~ /^>/x ) {
		$sequence = ">\n$sequence";
	}
	return $sequence;
}

sub _run_query {
	my ( $self, $seq_ref ) = @_;
	my $q           = $self->{'cgi'};
	my $page        = $q->param('page');
	my $sequence    = $self->_process_query_seq($seq_ref);
	my $stringfh_in = IO::String->new($sequence);
	my $seqin       = Bio::SeqIO->new( -fh => $stringfh_in, -format => 'fasta' );
	my $locus       = $q->param('locus');
	$locus =~ s/^cn_//x;
	$locus //= 0;
	my $distinct_locus_selected = $self->_is_distinct_locus_selected($locus);
	my $cleaned_locus           = $self->clean_locus($locus);
	my $locus_info              = $self->{'datastore'}->get_locus_info($locus);

	if ( $distinct_locus_selected && !$locus_info ) {
		say q(<div class="box" id="statusbad"><p>Invalid locus passed.</p></div>);
		return;
	}
	if ( $page eq 'sequenceQuery' ) {
		$self->_run_single_query( $locus, $seqin );
	} else {
		$self->_run_batch_query( $locus, $seqin );
	}
	return;
}

sub _run_single_query {
	my ( $self, $locus, $seqin ) = @_;
	my $distinct_locus_selected = $self->_is_distinct_locus_selected($locus);
	my $locus_info              = $self->{'datastore'}->get_locus_info($locus);
	my $text_filename           = BIGSdb::Utils::get_random() . '.txt';
	my $word_size               = $self->_get_word_size($locus);
	my $seq_object              = $seqin->next_seq;
	my $seq                     = $seq_object->seq;
	if ($seq) {
		$seq =~ s/[\s|-]//gx;
		$seq = uc($seq);
	}
	my $qry_type = BIGSdb::Utils::sequence_type($seq);
	my $set_id   = $self->get_set_id;
	my ( $blast_file, $job ) = $self->{'datastore'}->run_blast(
		{
			locus     => $locus,
			seq_ref   => \$seq,
			qry_type  => $qry_type,
			cache     => 1,
			word_size => $word_size,
			set_id    => $set_id
		}
	);
	my $exact_matches = $self->_parse_exact_matches( \$seq, $locus, $blast_file );
	my $data_ref = {
		locus                   => $locus,
		locus_info              => $locus_info,
		qry_type                => $qry_type,
		distinct_locus_selected => $distinct_locus_selected,
		seq_ref                 => \$seq,
		linked_data             => $self->_data_linked_to_locus( $locus, 'client_dbase_loci_fields' ),
		extended_attributes     => $self->_data_linked_to_locus( $locus, 'locus_extended_attributes' ),
	};
	if (@$exact_matches) {
		$self->_output_single_query_exact( $exact_matches, $data_ref );
	} else {
		if ( $distinct_locus_selected && $qry_type ne $locus_info->{'data_type'} ) {
			unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
			$self->_output_single_query_nonexact_mismatched($data_ref);
			$self->_delete_temp_files($blast_file);
			say q(</div>);
			return;
		}
		my $partial_match = $self->parse_blast_partial($blast_file);
		if ( defined $partial_match->{'allele'} ) {
			$self->_output_single_query_nonexact( $partial_match, $data_ref );
		} else {
			say q(<div class="box" id="statusbad"><p>No matches found.</p>);
			$self->_translate_button( \$seq ) if $qry_type eq 'DNA';
			say q(</div>);
		}
	}
	unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	$self->_delete_temp_files($job);
	return;
}

sub _run_batch_query {
	my ( $self, $locus, $seqin ) = @_;
	my $distinct_locus_selected = $self->_is_distinct_locus_selected($locus);
	my $locus_info              = $self->{'datastore'}->get_locus_info($locus);
	my $batch_buffer;
	my $td = 1;
	local $| = 1;
	my $first         = 1;
	my $job           = 0;
	my $text_filename = BIGSdb::Utils::get_random() . '.txt';
	my $word_size     = $self->_get_word_size($locus);
	while ( my $seq_object = $seqin->next_seq ) {

		if ( $ENV{'MOD_PERL'} ) {
			$self->{'mod_perl_request'}->rflush;
			return if $self->{'mod_perl_request'}->connection->aborted;
		}
		my $seq = $seq_object->seq;
		if ($seq) {
			$seq =~ s/[\s|-]//gx;
			$seq = uc($seq);
		}
		my $qry_type = BIGSdb::Utils::sequence_type($seq);
		my $set_id   = $self->get_set_id;
		( my $blast_file, $job ) = $self->{'datastore'}->run_blast(
			{
				locus     => $locus,
				seq_ref   => \$seq,
				qry_type  => $qry_type,
				cache     => 1,
				job       => $job,
				word_size => $word_size,
				set_id    => $set_id
			}
		);
		my $exact_matches = $self->_parse_exact_matches( \$seq, $locus, $blast_file );
		my $data_ref = {
			locus                   => $locus,
			locus_info              => $locus_info,
			qry_type                => $qry_type,
			distinct_locus_selected => $distinct_locus_selected,
			td                      => $td,
			seq_ref                 => \$seq,
			id                      => $seq_object->id // '',
			job                     => $job,
			linked_data             => $self->_data_linked_to_locus( $locus, 'client_dbase_loci_fields' ),
			extended_attributes     => $self->_data_linked_to_locus( $locus, 'locus_extended_attributes' ),
		};
		if (@$exact_matches) {
			$batch_buffer = $self->_output_batch_query_exact( $exact_matches, $data_ref, $text_filename );
		} else {
			if ( $distinct_locus_selected && $qry_type ne $locus_info->{'data_type'} ) {
				unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
			}
			my $partial_match = $self->parse_blast_partial($blast_file);
			if ( defined $partial_match->{'allele'} ) {
				$batch_buffer = $self->_output_batch_query_nonexact( $partial_match, $data_ref, $text_filename );
			} else {
				my $id = $seq_object->id // q();
				$batch_buffer =
				  qq(<tr class="td$td"><td>$id</td><td style="text-align:left">) . qq(No matches found.</td></tr>\n);
				open( my $fh, '>>', "$self->{'config'}->{'tmp_dir'}/$text_filename" )
				  || $logger->error("Can't open $text_filename for appending");
				say $fh qq($id: No matches found);
				close $fh;
			}
		}
		unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
		$td = $td == 1 ? 2 : 1;
		if ($first) {
			say q(<div class="box" id="resultsheader">);
			say q(<table class="resultstable"><tr><th>Sequence</th><th>Results</th></tr>);
			$first = 0;
		}
		print $batch_buffer if $batch_buffer;
	}
	$self->_delete_temp_files($job);
	if ($batch_buffer) {
		say q(</table>);
		my $table_file = $self->_generate_batch_table;
		say qq(<p>Text format: <a href="/tmp/$text_filename">list</a>);
		if ( -e "$self->{'config'}->{'tmp_dir'}/$table_file" ) {
			say qq( | <a href="/tmp/$table_file">table</a>);
		}
		say q(</p></div>);
	}
	return;
}

sub _delete_temp_files {
	my ( $self, $file ) = @_;

	#If BLAST output file is passed, also delete related files.
	$file =~ s/_outfile.txt//x;
	my @files = glob("$self->{'config'}->{'secure_tmp_dir'}/$file*");
	foreach (@files) { unlink $1 if /^(.*BIGSdb.*)$/x }
	return;
}

sub _generate_batch_table {
	my ($self)     = @_;
	my $table_file = BIGSdb::Utils::get_random() . '_table.txt';
	my $full_path  = "$self->{'config'}->{'tmp_dir'}/$table_file";
	my %loci;
	return $table_file if !ref $self->{'batch_results'};
	$self->{'batch_results'} //= {};
	foreach my $id ( keys %{ $self->{'batch_results'} } ) {
		foreach my $locus ( keys %{ $self->{'batch_results'}->{$id} } ) {
			$loci{$locus} = 1;
		}
	}
	my $set_id = $self->get_set_id;
	my $schemes = $self->{'datastore'}->get_scheme_list( { with_pk => 1, set_id => $set_id } );
	my @valid_schemes;
  SCHEME: foreach my $scheme (@$schemes) {
		my $scheme_loci = $self->{'datastore'}->get_scheme_loci( $scheme->{'id'} );
	  LOCUS: foreach my $scheme_loci (@$scheme_loci) {
			next SCHEME if !$loci{$scheme_loci};    # We have no data for this locus
		}
		push @valid_schemes, $scheme->{'id'};
	}
	my @loci = sort keys %loci;
	$self->{'batch_results_ids'} //= [];
	local $" = qq(\t);
	open( my $fh, '>', $full_path ) || $logger->error("Cannot open $full_path for writing");
	print $fh qq(id\t@loci);
	foreach my $scheme_id (@valid_schemes) {
		my $scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
		print $fh qq(\t@$scheme_fields);
	}
	print $fh qq(\n);
	foreach my $id ( @{ $self->{'batch_results_ids'} } ) {
		print $fh $id;
		foreach my $locus (@loci) {
			local $" = q(; );
			$self->{'batch_results'}->{$id}->{$locus} //= [];
			print $fh qq(\t@{$self->{'batch_results'}->{$id}->{$locus}});
		}
		foreach my $scheme_id (@valid_schemes) {
			my $scheme_loci = $self->{'datastore'}->get_scheme_loci($scheme_id);
			my @args;
			my @cleaned_loci;
			foreach my $scheme_locus (@$scheme_loci) {
				local $" = q(; );
				$self->{'batch_results'}->{$id}->{$scheme_locus} //= [];
				push @args, "@{$self->{'batch_results'}->{$id}->{$scheme_locus}}";
				push @cleaned_loci, $self->{'datastore'}->get_scheme_warehouse_locus_name( $scheme_id, $scheme_locus );
			}
			my $scheme_warehouse = qq(mv_scheme_$scheme_id);
			my $scheme_fields    = $self->{'datastore'}->get_scheme_fields($scheme_id);
			local $" = q(,);
			my $qry = qq(SELECT @$scheme_fields FROM $scheme_warehouse WHERE );
			local $" = q( IN (?,'N') AND );
			$qry .= qq(@cleaned_loci IN (?,'N'));
			my $field_values = $self->{'datastore'}->run_query( $qry, \@args, { fetch => 'row_arrayref' } );

			if ( !$field_values ) {
				@$field_values = (undef) x @$scheme_fields;
			}
			foreach my $value (@$field_values) {
				$value //= q();
				print $fh qq(\t$value);
			}
		}
		print $fh qq(\n);
	}
	close $full_path;
	return $table_file;
}

sub _translate_button {
	my ( $self, $seq_ref ) = @_;
	return if ref $seq_ref ne 'SCALAR' || length $$seq_ref < 3 || length $$seq_ref > 10000;
	return if !$self->{'config'}->{'emboss_path'};
	my $q = $self->{'cgi'};
	say $q->start_form;
	$q->param( page     => 'sequenceTranslate' );
	$q->param( sequence => $$seq_ref );
	say $q->hidden($_) foreach (qw (db page sequence));
	say $q->submit( -label => 'Translate query', -class => BUTTON_CLASS );
	say $q->end_form;
	return;
}

sub _output_single_query_exact {
	my ( $self, $exact_matches, $data ) = @_;
	my ( $locus, $qry_type, $distinct_locus_selected, $locus_info ) =
	  @{$data}{qw(locus qry_type distinct_locus_selected locus_info)};
	my $q = $self->{'cgi'};
	my %designations;
	my $buffer = qq(<div class="box" id="resultstable">\n);
	if ( ( $locus_info->{'data_type'} // '' ) eq 'peptide' && $qry_type eq 'DNA' ) {
		$buffer .= q(<p>Please note that as this is a peptide locus, the length corresponds to the peptide )
		  . q(translated from your query sequence.</p>);
	} elsif ( ( $locus_info->{'data_type'} // '' ) eq 'DNA' && $qry_type eq 'peptide' ) {
		$buffer .= q(<p>Please note that as this is a DNA locus, the length corresponds to the matching )
		  . q(nucleotide sequence that was translated to align against your peptide query sequence.</p>);
	}
	if ( !$distinct_locus_selected && $q->param('order') eq 'locus' ) {
		my %locus_values;
		foreach my $match (@$exact_matches) {
			if ( $match->{'allele'} =~ /(.*):.*/x ) {
				$locus_values{$match} = $1;
			}
		}
		@$exact_matches = sort { $locus_values{$a} cmp $locus_values{$b} } @$exact_matches;
	}
	my $displayed;
	if ($distinct_locus_selected) {
		( my $locus_buffer, $displayed ) = $self->_get_distinct_locus_exact_results( $locus, $exact_matches, $data );
		$buffer .= $locus_buffer;
	} else {
		( my $locus_buffer, $displayed ) = $self->_get_scheme_exact_results( $locus, $exact_matches, $data );
		$buffer .= $locus_buffer;
	}
	say q(<div class="box" id="resultsheader"><p>);
	say qq($displayed exact match) . ( $displayed > 1 ? 'es' : '' ) . q( found.</p>);
	$self->_translate_button( $data->{'seq_ref'} ) if $qry_type eq 'DNA';
	say q(</div>);
	say $buffer;
	say q(</div>);
	return;
}

sub _get_table_header {
	my ( $self, $data ) = @_;
	my $buffer =
	    q(<table class="resultstable"><tr><th>Allele</th><th>Length</th>)
	  . q(<th>Start position</th><th>End position</th>)
	  . ( $data->{'linked_data'}         ? '<th>Linked data values</th>' : q() )
	  . ( $data->{'extended_attributes'} ? '<th>Attributes</th>'         : q() )
	  . ( ( $self->{'system'}->{'allele_flags'}    // '' ) eq 'yes' ? q(<th>Flags</th>)    : q() )
	  . ( ( $self->{'system'}->{'allele_comments'} // '' ) eq 'yes' ? q(<th>Comments</th>) : q() )
	  . q(</tr>);
	return $buffer;
}

sub _get_distinct_locus_exact_results {
	my ( $self, $locus, $exact_matches, $data ) = @_;
	my $locus_info  = $self->{'datastore'}->get_locus_info($locus);
	my $match_count = 0;
	my $td          = 1;
	my $buffer      = qq(<div class="scrollable">\n);
	$buffer .= $self->_get_table_header($data);
	foreach my $match (@$exact_matches) {
		my $allele;
		my ( $field_values, $attributes, $allele_info, $flags );
		$match_count++;
		next if $locus_info->{'match_longest'} && $match_count > 1;
		my $cleaned = $self->clean_locus( $locus, { strip_links => 1 } );
		$buffer .= qq(<tr class="td$td"><td><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;)
		  . qq(page=alleleInfo&amp;locus=$locus&amp;allele_id=$match->{'allele'}">);
		$allele = "$cleaned: $match->{'allele'}";
		$field_values =
		  $self->{'datastore'}->get_client_data_linked_to_allele( $locus, $match->{'allele'}, { table_format => 1 } );
		$attributes = $self->{'datastore'}->get_allele_attributes( $locus, [ $match->{'allele'} ] );
		$allele_info = $self->{'datastore'}->run_query(
			'SELECT * FROM sequences WHERE (locus,allele_id)=(?,?)',
			[ $locus, $match->{'allele'} ],
			{ fetch => 'row_hashref' }
		);
		$flags = $self->{'datastore'}->get_allele_flags( $locus, $match->{'allele'} );
		$buffer .= qq($allele</a></td><td>$match->{'length'}</td><td>$match->{'start'}</td><td>$match->{'end'}</td>);
		$buffer .= defined $field_values ? qq(<td style="text-align:left">$field_values</td>) : q(<td></td>)
		  if $data->{'linked_data'};
		$buffer .= defined $attributes ? qq(<td style="text-align:left">$attributes</td>) : q(<td></td>)
		  if $data->{'extended_attributes'};

		if ( ( $self->{'system'}->{'allele_flags'} // '' ) eq 'yes' ) {
			local $" = q(</a> <a class="seqflag_tooltip">);
			$buffer .=
			  @$flags ? qq(<td style="text-align:left"><a class="seqflag_tooltip">@$flags</a></td>) : q(<td></td>);
		}
		if ( ( $self->{'system'}->{'allele_comments'} // '' ) eq 'yes' ) {
			$buffer .= $allele_info->{'comments'} ? qq(<td>$allele_info->{'comments'}</td>) : q(<td></td>);
		}
		$buffer .= qq(</tr>\n);
		$td = $td == 1 ? 2 : 1;
	}
	$buffer .= qq(</table></div>\n);
	return ( $buffer, $match_count );
}

sub _get_scheme_exact_results {
	my ( $self, $scheme_param, $exact_matches, $data ) = @_;
	my %locus_matches;
	my $set_id = $self->get_set_id;
	my @schemes;
	if ( $scheme_param =~ /SCHEME_(\d+)/x ) {
		push @schemes, $1;
	} elsif ( $scheme_param =~ /GROUP_(\d+)/x ) {
		my $group_schemes = $self->{'datastore'}->get_schemes_in_group( $1, { set_id => $set_id } );
		push @schemes, @$group_schemes;
	} else {
		push @schemes, 0;
	}
	my $displayed = 0;
	my %designations;
	my $buffer = q();
	foreach my $scheme_id (@schemes) {
		my $scheme_buffer;
		my $td = 1;
		my $scheme_members;
		if ($scheme_id) {
			$scheme_members = $self->{'datastore'}->get_scheme_loci($scheme_id);
		} else {
			$scheme_members = $self->{'datastore'}->get_loci( { set_id => $set_id } );
		}
		my %locus_in_scheme = map { $_ => 1 } @$scheme_members;
		foreach my $match (@$exact_matches) {
			my $allele;
			my ( $field_values, $attributes, $allele_info, $flags );
			next if $match->{'allele'} !~ /(.*):(.*)/x;
			my ( $extracted_locus, $allele_id ) = ( $1, $2 );    ## no critic (ProhibitCaptureWithoutTest)
			next if !$locus_in_scheme{$extracted_locus};
			$designations{$extracted_locus} = $allele_id;
			my $locus_info = $self->{'datastore'}->get_locus_info($extracted_locus);
			$locus_matches{$extracted_locus}++;
			next if $locus_info->{'match_longest'} && $locus_matches{$extracted_locus} > 1;
			my $cleaned = $self->clean_locus( $extracted_locus, { strip_links => 1 } );
			$allele = "$cleaned: $allele_id";
			$field_values =
			  $self->{'datastore'}
			  ->get_client_data_linked_to_allele( $extracted_locus, $allele_id, { table_format => 1 } );
			$attributes = $self->{'datastore'}->get_allele_attributes( $extracted_locus, [$allele_id] );
			$allele_info = $self->{'datastore'}->run_query(
				'SELECT * FROM sequences WHERE (locus,allele_id)=(?,?)',
				[ $extracted_locus, $allele_id ],
				{ fetch => 'row_hashref' }
			);
			$flags = $self->{'datastore'}->get_allele_flags( $extracted_locus, $allele_id );

			if ( !$scheme_buffer ) {
				if ($scheme_id) {
					my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id } );
					$scheme_buffer .= qq(<h2>$scheme_info->{'name'}</h2>);
				}
				$scheme_buffer .= qq(<div class="scrollable">\n);
				$scheme_buffer .= $self->_get_table_header($data);
			}
			$scheme_buffer .=
			    qq(<tr class="td$td"><td><a href="$self->{'system'}->{'script_name'}?)
			  . qq(db=$self->{'instance'}&amp;page=alleleInfo&amp;locus=$extracted_locus&amp;)
			  . qq(allele_id=$allele_id">)
			  if $extracted_locus && $allele_id;
			$scheme_buffer .=
			  qq($allele</a></td><td>$match->{'length'}</td><td>$match->{'start'}</td><td>$match->{'end'}</td>);
			$scheme_buffer .= defined $field_values ? qq(<td style="text-align:left">$field_values</td>) : q(<td></td>)
			  if $data->{'linked_data'};
			$scheme_buffer .= defined $attributes ? qq(<td style="text-align:left">$attributes</td>) : q(<td></td>)
			  if $data->{'extended_attributes'};
			if ( ( $self->{'system'}->{'allele_flags'} // '' ) eq 'yes' ) {
				local $" = q(</a> <a class="seqflag_tooltip">);
				$scheme_buffer .=
				  @$flags ? qq(<td style="text-align:left"><a class="seqflag_tooltip">@$flags</a></td>) : q(<td></td>);
			}
			if ( ( $self->{'system'}->{'allele_comments'} // '' ) eq 'yes' ) {
				$scheme_buffer .= $allele_info->{'comments'} ? qq(<td>$allele_info->{'comments'}</td>) : q(<td></td>);
			}
			$scheme_buffer .= qq(</tr>\n);
			$displayed++;
			$td = $td == 1 ? 2 : 1;
		}
		if ($scheme_buffer) {
			$buffer .= qq(<div class="scrollable">\n);
			$buffer .= $scheme_buffer;
			$buffer .= qq(</table></div>\n);
		}
		$buffer .= $self->_get_scheme_fields( $scheme_id, \%designations );
	}
	if ( !@schemes ) {
		$buffer .= $self->_get_scheme_fields( 0, \%designations );
	}
	return ( $buffer, $displayed );
}

sub _get_scheme_fields {
	my ( $self, $scheme_id, $designations ) = @_;
	my $buffer = q();
	my $set_id = $self->get_set_id;
	if ( !$scheme_id ) {    #all loci
		my $schemes = $self->get_scheme_data( { with_pk => 1 } );
		foreach my $scheme (@$schemes) {
			my $scheme_loci = $self->{'datastore'}->get_scheme_loci( $scheme->{'id'} );
			if ( any { defined $designations->{$_} } @$scheme_loci ) {
				$buffer .= $self->_get_scheme_table( $scheme->{'id'}, $designations );
			}
		}
	} else {
		my $scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
		my $scheme_loci   = $self->{'datastore'}->get_scheme_loci($scheme_id);
		if ( @$scheme_fields && @$scheme_loci ) {
			$buffer .= $self->_get_scheme_table( $scheme_id, $designations );
		}
	}
	return $buffer;
}

sub _get_scheme_table {
	my ( $self, $scheme_id, $designations ) = @_;
	my ( @profile, @temp_qry );
	my $set_id = $self->get_set_id;
	my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id, get_pk => 1 } );
	return q() if !defined $scheme_info->{'primary_key'};
	my $scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
	my $scheme_loci   = $self->{'datastore'}->get_scheme_loci($scheme_id);
	foreach my $locus (@$scheme_loci) {
		push @profile, $designations->{$locus};
		$designations->{$locus} //= 0;
		$designations->{$locus} =~ s/'/\\'/gx;
		my $locus_profile_name = $self->{'datastore'}->get_scheme_warehouse_locus_name( $scheme_id, $locus );
		my $temp_qry = "$locus_profile_name=E'$designations->{$locus}'";
		$temp_qry .= " OR $locus_profile_name='N'" if $scheme_info->{'allow_missing_loci'};
		push @temp_qry, $temp_qry;
	}
	if ( none { !defined $_ } @profile || $scheme_info->{'allow_missing_loci'} ) {
		local $" = ') AND (';
		my $temp_qry_string = "@temp_qry";
		local $" = ',';
		my $values =
		  $self->{'datastore'}->run_query( "SELECT @$scheme_fields FROM mv_scheme_$scheme_id WHERE ($temp_qry_string)",
			undef, { fetch => 'row_hashref' } );
		my $buffer;
		$buffer .= qq(<h2>$scheme_info->{'name'}</h2>) if $self->{'cgi'}->param('locus') eq '0';
		$buffer .= q(<table style="margin-top:1em">);
		my $td = 1;

		foreach my $field (@$scheme_fields) {
			my $value = $values->{ lc($field) } // 'Not defined';
			my $primary_key = $field eq $scheme_info->{'primary_key'} ? 1 : 0;
			return q() if $primary_key && $value eq 'Not defined';
			$field =~ tr/_/ /;
			$buffer .= qq(<tr class="td$td"><th>$field</th><td>);
			$buffer .=
			  $primary_key
			  ? qq(<a href="$self->{'system'}->{'script_name'}?page=profileInfo&amp;db=$self->{'instance'}&amp;)
			  . qq(scheme_id=$scheme_id&amp;profile_id=$value">$value</a>)
			  : $value;
			$buffer .= q(</td></tr>);
			$td = $td == 1 ? 2 : 1;
		}
		$buffer .= q(</table>);
		return $buffer;
	}
	return q();
}

sub _output_batch_query_exact {
	my ( $self,  $exact_matches,           $data, $filename ) = @_;
	my ( $locus, $distinct_locus_selected, $td,   $id )       = @{$data}{qw(locus distinct_locus_selected td id)};
	my $q      = $self->{'cgi'};
	my $buffer = '';
	if ( !$distinct_locus_selected && $q->param('order') eq 'locus' ) {
		my %locus_values;
		foreach (@$exact_matches) {
			if ( $_->{'allele'} =~ /(.*):.*/x ) {
				$locus_values{$_} = $1;
			}
		}
		@$exact_matches = sort { $locus_values{$a} cmp $locus_values{$b} } @$exact_matches;
	}
	my $first       = 1;
	my $text_buffer = '';
	my %locus_matches;
	my $displayed = 0;
	push @{ $self->{'batch_results_ids'} }, $id;
	foreach (@$exact_matches) {
		my $allele_id;
		if ( !$distinct_locus_selected && $_->{'allele'} =~ /(.*):(.*)/x ) {
			( $locus, $allele_id ) = ( $1, $2 );
		} else {
			$allele_id = $_->{'allele'};
		}
		my $locus_info = $self->{'datastore'}->get_locus_info($locus);
		$locus_matches{$locus}++;
		next if $locus_info->{'match_longest'} && $locus_matches{$locus} > 1;
		if ( !$first ) {
			$buffer      .= '; ';
			$text_buffer .= '; ';
		}
		my $cleaned_locus = $self->clean_locus( $locus, { strip_links => 1 } );
		my $text_locus = $self->clean_locus( $locus, { text_output => 1, no_common_name => 1 } );
		$buffer .= qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleInfo&amp;)
		  . qq(locus=$locus&amp;allele_id=$allele_id">$cleaned_locus: $allele_id</a>);
		$text_buffer .= "$text_locus-$allele_id";
		$displayed++;
		undef $locus if !$distinct_locus_selected;
		$first = 0;
		push @{ $self->{'batch_results'}->{$id}->{$text_locus} }, $allele_id;
	}
	open( my $fh, '>>', "$self->{'config'}->{'tmp_dir'}/$filename" )
	  or $logger->error("Can't open $filename for appending");
	say $fh "$id: $text_buffer";
	close $fh;
	return
	    qq(<tr class="td$td"><td>$id</td><td style="text-align:left">)
	  . q(Exact match)
	  . ( $displayed == 1 ? '' : 'es' )
	  . qq( found: $buffer</td></tr>\n);
}

sub _output_single_query_nonexact_mismatched {
	my ( $self, $data ) = @_;
	my $set_id = $self->get_set_id;
	my ( $blast_file, undef ) = $self->{'datastore'}->run_blast(
		{
			locus       => $data->{'locus'},
			seq_ref     => $data->{'seq_ref'},
			qry_type    => $data->{'qry_type'},
			num_results => 5,
			alignment   => 1,
			set_id      => $set_id
		}
	);
	say q(<div class="box" id="resultsheader">);
	if ( -e "$self->{'config'}->{'secure_tmp_dir'}/$blast_file" ) {
		say qq(<p>Your query is a $data->{'qry_type'} sequence whereas this locus is defined with )
		  . qq($data->{'locus_info'}->{'data_type'} sequences.  There were no exact matches, but the )
		  . q(BLAST results are shown below (a maximum of five alignments are displayed).</p>);
		say q(<pre style="font-size:1.4em; padding: 1em; border:1px black dashed">);
		$self->print_file( "$self->{'config'}->{'secure_tmp_dir'}/$blast_file", { ignore_hashlines => 1 } );
		say q(</pre>);
	} else {
		say q(<p>No results from BLAST.</p>);
	}
	$blast_file =~ s/outfile.txt//x;
	my @files = glob("$self->{'config'}->{'secure_tmp_dir'}/$blast_file*");
	foreach (@files) { unlink $1 if /^(.*BIGSdb.*)$/x }
	return;
}

sub _output_single_query_nonexact {
	my ( $self, $partial_match, $data ) = @_;
	my ( $locus, $qry_type, $distinct_locus_selected, $seq_ref ) =
	  @{$data}{qw(locus qry_type distinct_locus_selected seq_ref)};
	say q(<div class="box" id="resultsheader">);
	$self->_translate_button( $data->{'seq_ref'} ) if $qry_type eq 'DNA';
	say q(<p style="margin-top:0.5em">Closest match: );
	my $cleaned_match = $partial_match->{'allele'};
	my $cleaned_locus;
	my ( $flags, $field_values );

	if ($distinct_locus_selected) {
		say qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleInfo&amp;)
		  . qq(locus=$locus&amp;allele_id=$cleaned_match">);
		$cleaned_locus = $self->clean_locus( $locus, { strip_links => 1 } );
		say qq($cleaned_locus: );
		$flags = $self->{'datastore'}->get_allele_flags( $locus, $cleaned_match );
		$field_values = $self->{'datastore'}->get_client_data_linked_to_allele( $locus, $cleaned_match );
	} else {
		my ( $extracted_locus, $allele_id );
		if ( $cleaned_match =~ /(.*):(.*)/x ) {
			( $extracted_locus, $allele_id ) = ( $1, $2 );
			$cleaned_locus = $self->clean_locus( $extracted_locus, { strip_links => 1 } );
			$cleaned_match = qq($cleaned_locus: $allele_id);
			say qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleInfo&amp;)
			  . qq(locus=$extracted_locus&amp;allele_id=$allele_id">);
			$flags = $self->{'datastore'}->get_allele_flags( $extracted_locus, $allele_id );
			$field_values = $self->{'datastore'}->get_client_data_linked_to_allele( $extracted_locus, $allele_id );
		}
	}
	say qq($cleaned_match</a>);
	if ( ref $flags eq 'ARRAY' ) {
		local $" = q(</a> <a class="seqflag_tooltip">);
		my $plural = @$flags == 1 ? '' : 's';
		say qq( (Flag$plural: <a class="seqflag_tooltip">@$flags</a>)) if @$flags;
	}
	say q(</p>);
	if ($field_values) {
		say q(<p>This match is linked to the following data:</p>);
		say $field_values;
	}
	my ( $locus_data_type, $allele_seq_ref );
	if ($distinct_locus_selected) {
		$allele_seq_ref = $self->{'datastore'}->get_sequence( $locus, $partial_match->{'allele'} );
		$locus_data_type = $data->{'locus_info'}->{'data_type'};
	} else {
		my ( $extracted_locus, $allele ) = split /:/x, $partial_match->{'allele'};
		$allele_seq_ref = $self->{'datastore'}->get_sequence( $extracted_locus, $allele );
		$locus_data_type = $self->{'datastore'}->get_locus_info($extracted_locus)->{'data_type'};
	}
	say q(</div>);
	say q(<div class="box" id="resultspanel">);
	if ( $locus_data_type eq $data->{'qry_type'} ) {
		$self->_display_differences(
			{
				locus                   => $locus,
				cleaned_match           => $cleaned_match,
				distinct_locus_selected => $distinct_locus_selected,
				partial_match           => $partial_match,
				seq_ref                 => $seq_ref,
				allele_seq_ref          => $allele_seq_ref,
				qry_type                => $qry_type
			}
		);
	} else {
		my $set_id = $self->get_set_id;
		my ( $blast_file, undef ) = $self->{'datastore'}->run_blast(
			{
				locus       => $locus,
				seq_ref     => $seq_ref,
				qry_type    => $qry_type,
				num_results => 5,
				alignment   => 1,
				cache       => 1,
				job         => $data->{'job'},
				set_id      => $set_id
			}
		);
		if ( -e "$self->{'config'}->{'secure_tmp_dir'}/$blast_file" ) {
			say qq(<p>Your query is a $qry_type sequence whereas this locus is defined with )
			  . ( $qry_type eq 'DNA' ? 'peptide' : 'DNA' )
			  . q( sequences.  There were no exact matches, but the BLAST results are shown below )
			  . q((a maximum of five alignments are displayed).</p>);
			say q(<pre style="font-size:1.4em; padding: 1em; border:1px black dashed">);
			$self->print_file( "$self->{'config'}->{'secure_tmp_dir'}/$blast_file", { ignore_hashlines => 1 } );
			say q(</pre>);
		} else {
			say q(<p>No results from BLAST.</p>);
		}
		unlink "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	}
	say q(</div>);
	return;
}

sub _display_differences {
	my ( $self, $args ) = @_;
	my ( $locus, $cleaned_match, $distinct_locus_selected, $partial_match, $seq_ref, $allele_seq_ref, $qry_type ) =
	  @$args{qw(locus cleaned_match distinct_locus_selected partial_match seq_ref allele_seq_ref qry_type)};
	my $temp        = BIGSdb::Utils::get_random();
	my $seq1_infile = "$self->{'config'}->{'secure_tmp_dir'}/$temp\_file1.txt";
	my $seq2_infile = "$self->{'config'}->{'secure_tmp_dir'}/$temp\_file2.txt";
	my $outfile     = "$self->{'config'}->{'tmp_dir'}/$temp\_outfile.txt";
	open( my $seq1_fh, '>', $seq2_infile ) || $logger->error("Can't open $seq2_infile for writing");
	say $seq1_fh ">Ref\n$$allele_seq_ref";
	close $seq1_fh;
	open( my $seq2_fh, '>', $seq1_infile ) || $logger->error("Can't open $seq1_infile for writing");
	say $seq2_fh ">Query\n$$seq_ref";
	close $seq2_fh;
	my $start      = $partial_match->{'qstart'} =~ /(\d+)/x ? $1 : undef;    #untaint
	my $end        = $partial_match->{'qend'}   =~ /(\d+)/x ? $1 : undef;
	my $seq_length = ( length $$seq_ref )       =~ /(\d+)/x ? $1 : undef;
	my $reverse = $partial_match->{'reverse'} ? 1 : 0;
	my @args = (
		-aformat   => 'markx2',
		-awidth    => $self->{'prefs'}->{'alignwidth'},
		-asequence => $seq1_infile,
		-bsequence => $seq2_infile,
		-sreverse1 => $reverse,
		-outfile   => $outfile
	);
	push @args, ( -sbegin1 => $start, -send1 => $end ) if $seq_length > 10000;
	system("$self->{'config'}->{'emboss_path'}/stretcher @args 2>/dev/null");
	unlink $seq1_infile, $seq2_infile;

	if ( !$partial_match->{'gaps'} ) {
		my $qstart = $partial_match->{'qstart'};
		my $sstart = $partial_match->{'sstart'};
		my $ssend  = $partial_match->{'send'};
		while ( $sstart > 1 && $qstart > 1 ) {
			$sstart--;
			$qstart--;
		}
		if ($reverse) {
			say q(<p>The sequence is reverse-complemented with respect to the reference sequence. )
			  . q(The list of differences is disabled but you can use the alignment or try reversing )
			  . q(it and querying again.</p>);
			print $self->get_alignment( $outfile, $temp );
		} else {
			print $self->get_alignment( $outfile, $temp );
			my $diffs = $self->_get_differences( $allele_seq_ref, $seq_ref, $sstart, $qstart );
			say q(<h2>Differences</h2>);
			if (@$diffs) {
				my $plural = @$diffs > 1 ? 's' : '';
				say q(<p>) . @$diffs . qq( difference$plural found. );
				say qq(<a class="tooltip" title="differences - The information to the left of the arrow$plural )
				  . q(shows the identity and position on the reference sequence and the information to the )
				  . q(right shows the corresponding identity and position on your query sequence.">)
				  . q(<span class="fa fa-info-circle"></span></a>);
				say q(</p><p>);
				my $pos = 0;
				foreach my $diff (@$diffs) {
					$pos++;
					next if $pos < $sstart;
					if ( $diff->{'qbase'} eq 'missing' ) {
						say qq(Truncated at position $diff->{'spos'} on reference sequence.);
						last;
					}
					say $self->_format_difference( $diff, $qry_type ) . q(<br />);
				}
				say q(</p>);
				if ( $sstart > 1 ) {
					say qq(<p>Your query sequence only starts at position $sstart of sequence );
					say qq($locus: ) if $locus && $locus !~ /SCHEME_\d+/x && $locus !~ /GROUP_\d+/x;
					say qq($cleaned_match.</p>);
				} else {
					say q(<p>The locus start point is at position )
					  . ( $qstart - $sstart + 1 )
					  . q( of your query sequence.);
					say q( <a class="tooltip" title="start position - This may be approximate if there are )
					  . q(gaps near the beginning of the alignment between your query and the reference )
					  . q(sequence."><span class="fa fa-info-circle"></span></a></p>);
				}
			} else {
				print qq(<p>Your query sequence only starts at position $sstart of sequence );
				print qq($locus: ) if $distinct_locus_selected;
				say qq($partial_match->{'allele'}.</p>);
			}
		}
	} else {
		say q(<p>An alignment between your query and the returned reference sequence is shown rather )
		  . q(than a simple list of differences because there are gaps in the alignment.</p>);
		say q(<pre style="font-size:1.2em">);
		$self->print_file( $outfile, { ignore_hashlines => 1 } );
		say q(</pre>);
		my @files = glob("$self->{'config'}->{'secure_tmp_dir'}/$temp*");
		foreach (@files) { unlink $1 if /^(.*BIGSdb.*)$/x }
	}
	return;
}

sub get_alignment {
	my ( $self, $outfile, $outfile_prefix ) = @_;
	my $buffer = '';
	if ( -e $outfile ) {
		my $cleaned_file = "$self->{'config'}->{'tmp_dir'}/$outfile_prefix\_cleaned.txt";
		$self->_cleanup_alignment( $outfile, $cleaned_file );
		$buffer .= qq(<p><a href="/tmp/$outfile_prefix\_cleaned.txt" id="alignment_link" data-rel="ajax">)
		  . qq(Show alignment</a></p>\n);
		$buffer .= qq(<pre style="font-size:1.2em"><span id="alignment"></span></pre>\n);
	}
	return $buffer;
}

sub _output_batch_query_nonexact {
	my ( $self, $partial_match, $data, $filename ) = @_;
	my ( $locus, $distinct_locus_selected ) = @{$data}{qw(locus distinct_locus_selected )};
	my ( $batch_buffer, $buffer, $text_buffer );
	my $allele_seq_ref;
	if ($distinct_locus_selected) {
		$allele_seq_ref = $self->{'datastore'}->get_sequence( $locus, $partial_match->{'allele'} );
	} else {
		my ( $extracted_locus, $allele ) = split /:/x, $partial_match->{'allele'};
		$allele_seq_ref = $self->{'datastore'}->get_sequence( $extracted_locus, $allele );
	}
	if ( !$partial_match->{'gaps'} ) {
		my $qstart = $partial_match->{'qstart'};
		my $sstart = $partial_match->{'sstart'};
		my $ssend  = $partial_match->{'send'};
		while ( $sstart > 1 && $qstart > 1 ) {
			$sstart--;
			$qstart--;
		}
		if ( $sstart > $ssend ) {
			$buffer      .= q(Reverse complemented - try reversing it and query again.);
			$text_buffer .= q(Reverse complemented - try reversing it and query again.);
		} else {
			my $diffs = $self->_get_differences( $allele_seq_ref, $data->{'seq_ref'}, $sstart, $qstart );
			if (@$diffs) {
				my $plural = @$diffs > 1 ? 's' : '';
				$buffer      .= (@$diffs) . " difference$plural found. ";
				$text_buffer .= (@$diffs) . " difference$plural found. ";
				my $first = 1;
				foreach my $diff (@$diffs) {
					if ( !$first ) {
						$buffer      .= '; ';
						$text_buffer .= '; ';
					}
					$buffer .= $self->_format_difference( $diff, $data->{'qry_type'} );
					$text_buffer .=
					  "\[$diff->{'spos'}\]$diff->{'sbase'}->\[" . ( $diff->{'qpos'} // '' ) . "\]$diff->{'qbase'}";
					$first = 0;
				}
			} else {
				$buffer      .= q(Gaps or missing sequence - try single sequence query to see alignment.);
				$text_buffer .= q(Gaps or missing sequence - try single sequence query to see alignment.);
			}
		}
	} else {
		$buffer .=
		  q(There are insertions/deletions between these sequences.  Try single sequence query to get more details.);
		$text_buffer .= q(Insertions/deletions present.);
	}
	my ( $allele, $text_allele, $cleaned_locus, $text_locus );
	if ($distinct_locus_selected) {
		$cleaned_locus = $self->clean_locus( $locus, { strip_links => 1 } );
		$text_locus = $self->clean_locus( $locus, { text_output => 1, no_common_name => 1 } );
		$allele = qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleInfo&amp;)
		  . qq(locus=$locus&amp;allele_id=$partial_match->{'allele'}\">$cleaned_locus: $partial_match->{'allele'}</a>);
		$text_allele = "$text_locus-$partial_match->{'allele'}";
	} else {
		if ( $partial_match->{'allele'} =~ /(.*):(.*)/x ) {
			my ( $extracted_locus, $allele_id ) = ( $1, $2 );
			$cleaned_locus = $self->clean_locus( $extracted_locus, { strip_links => 1 } );
			$text_locus = $self->clean_locus( $extracted_locus, { text_output => 1, no_common_name => 1 } );
			$partial_match->{'allele'} =~ s/:/: /x;
			$allele = qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleInfo&amp;)
			  . qq(locus=$extracted_locus&amp;allele_id=$allele_id">$cleaned_locus: $allele_id</a>);
			$text_allele = qq($text_locus-$allele_id);
		}
	}
	$batch_buffer = qq(<tr class="td$data->{'td'}"><td>$data->{'id'}</td><td style="text-align:left">)
	  . qq(Partial match found: $allele: $buffer</td></tr>\n);
	open( my $fh, '>>', "$self->{'config'}->{'tmp_dir'}/$filename" )
	  or $logger->error("Can't open $filename for appending");
	say $fh qq($data->{'id'}: Partial match: $text_allele: $text_buffer);
	close $fh;
	return $batch_buffer;
}

sub remove_all_identifier_lines {
	my ( $self, $seq_ref ) = @_;
	$$seq_ref =~ s/>.+\n//gx;
	return;
}

sub _format_difference {
	my ( $self, $diff, $qry_type ) = @_;
	my $buffer;
	if ( $qry_type eq 'DNA' ) {
		$buffer .= qq(<sup>$diff->{'spos'}</sup>);
		$buffer .= qq(<span class="$diff->{'sbase'}">$diff->{'sbase'}</span>);
		$buffer .= q( &rarr; );
		$buffer .= defined $diff->{'qpos'} ? qq(<sup>$diff->{'qpos'}</sup>) : q();
		$buffer .= qq(<span class="$diff->{'qbase'}">$diff->{'qbase'}</span>);
	} else {
		$buffer .= qq(<sup>$diff->{'spos'}</sup>);
		$buffer .= $diff->{'sbase'};
		$buffer .= q( &rarr; );
		$buffer .= defined $diff->{'qpos'} ? qq(<sup>$diff->{'qpos'}</sup>) : q();
		$buffer .= "$diff->{'qbase'}";
	}
	return $buffer;
}

sub parse_blast_diploid_exact {

	#BLAST+ treats ambiguous bases as mismatches - we'll use the the BLAST+ results file and check each match using
	#regular expressions instead.
	my ( $self, $qry_seq, $locus, $blast_file ) = @_;
	my $full_path = "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	return [] if !-e $full_path;
	my @matches;
	open( my $blast_fh, '<', $full_path )
	  || ( $logger->error("Can't open BLAST output file $full_path. $!"), return \@matches );
	while ( my $line = <$blast_fh> ) {
		next if !$line || $line =~ /^\#/x;
		my @record = split /\s+/x, $line;
		my $match;
		my $allele_seq;
		if ( $locus && $locus !~ /SCHEME_\d+/x && $locus !~ /GROUP_\d+/x ) {
			$allele_seq = $self->{'datastore'}->get_sequence( $locus, $record[1] );
		} else {
			my ( $extracted_locus, $allele ) = split /:/x, $record[1];
			$allele_seq = $self->{'datastore'}->get_sequence( $extracted_locus, $allele );
		}
		if ( $$allele_seq =~ /$$qry_seq/x ) {
			my $length = length $$allele_seq;
			$match->{'allele'}  = $record[1];
			$match->{'length'}  = $length;
			$match->{'start'}   = $-[0] + 1;
			$match->{'end'}     = $+[0];
			$match->{'reverse'} = 1 if ( $record[8] > $record[9] || $record[7] < $record[6] );
			push @matches, $match;
		}
	}
	close $blast_fh;
	return \@matches;
}

sub parse_blast_exact {
	my ( $self, $locus, $blast_file ) = @_;
	my $full_path = "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	return [] if !-e $full_path;
	my @matches;
	open( my $blast_fh, '<', $full_path )
	  || ( $logger->error("Can't open BLAST output file $full_path. $!"), return \@matches );
	while ( my $line = <$blast_fh> ) {
		my $match;
		next if !$line || $line =~ /^\#/x;
		my @record = split /\s+/x, $line;
		if ( $record[2] == 100 ) {    #identity
			my $seq_ref;
			if ( $locus && $locus !~ /SCHEME_\d+/x && $locus !~ /GROUP_\d+/x ) {
				$seq_ref = $self->{'datastore'}->get_sequence( $locus, $record[1] );
			} else {
				my ( $extracted_locus, $allele ) = split /:/x, $record[1];
				$seq_ref = $self->{'datastore'}->get_sequence( $extracted_locus, $allele );
			}
			my $length = length $$seq_ref;
			if (
				(
					(
						$record[8] == 1             #sequence start position
						&& $record[9] == $length    #end position
					)
					|| (
						$record[8] == $length       #sequence start position (reverse complement)
						&& $record[9] == 1          #end position
					)
				)
				&& !$record[4]                      #no gaps
			  )
			{
				$match->{'allele'}  = $record[1];
				$match->{'length'}  = $length;
				$match->{'start'}   = $record[6];
				$match->{'end'}     = $record[7];
				$match->{'reverse'} = 1 if ( $record[8] > $record[9] || $record[7] < $record[6] );
				push @matches, $match;
			}
		}
	}
	close $blast_fh;

	#Explicitly order by ascending length since this isn't guaranteed by BLASTX (seems that it should be but it isn't).
	@matches = sort { $b->{'length'} <=> $a->{'length'} } @matches;
	return \@matches;
}

sub parse_blast_partial {

	#return best match
	my ( $self, $blast_file ) = @_;
	my $full_path = "$self->{'config'}->{'secure_tmp_dir'}/$blast_file";
	return {} if !-e $full_path;
	open( my $blast_fh, '<', $full_path )
	  || ( $logger->error("Can't open BLAST output file $full_path. $!"), return {} );
	my %best_match;
	$best_match{'bit_score'} = 0;
	my %match;

	while ( my $line = <$blast_fh> ) {
		next if !$line || $line =~ /^\#/x;
		my @record = split /\s+/x, $line;
		$match{'allele'}    = $record[1];
		$match{'identity'}  = $record[2];
		$match{'alignment'} = $record[3];
		$match{'gaps'}      = $record[5];
		$match{'qstart'}    = $record[6];
		$match{'qend'}      = $record[7];
		$match{'sstart'}    = $record[8];
		$match{'send'}      = $record[9];
		if (   ( $record[8] > $record[9] && $record[7] > $record[6] )
			|| ( $record[8] < $record[9] && $record[7] < $record[6] ) )
		{
			$match{'reverse'} = 1;
		} else {
			$match{'reverse'} = 0;
		}
		$match{'bit_score'} = $record[11];
		if ( $match{'bit_score'} > $best_match{'bit_score'} ) {
			%best_match = %match;
		}
	}
	close $blast_fh;
	return \%best_match;
}

sub _get_differences {

	#returns differences between two sequences where there are no gaps
	my ( $self, $seq1_ref, $seq2_ref, $sstart, $qstart ) = @_;
	my $qpos = $qstart - 1;
	my @diffs;
	if ( $sstart > $qstart ) {
		foreach my $spos ( $qstart .. $sstart - 1 ) {
			my $diff;
			$diff->{'spos'}  = $spos;
			$diff->{'sbase'} = substr( $$seq1_ref, $spos, 1 );
			$diff->{'qbase'} = 'missing';
			push @diffs, $diff;
		}
	}
	for ( my $spos = $sstart - 1 ; $spos < length $$seq1_ref ; $spos++ ) {
		my $diff;
		$diff->{'spos'} = $spos + 1;
		$diff->{'sbase'} = substr( $$seq1_ref, $spos, 1 );
		if ( $qpos < length $$seq2_ref && substr( $$seq1_ref, $spos, 1 ) ne substr( $$seq2_ref, $qpos, 1 ) ) {
			$diff->{'qpos'} = $qpos + 1;
			$diff->{'qbase'} = substr( $$seq2_ref, $qpos, 1 );
			push @diffs, $diff;
		} elsif ( $qpos >= length $$seq2_ref ) {
			$diff->{'qbase'} = 'missing';
			push @diffs, $diff;
		}
		$qpos++;
	}
	return \@diffs;
}

sub _cleanup_alignment {
	my ( $self, $infile, $outfile ) = @_;
	open( my $in_fh,  '<', $infile )  || $logger->error("Can't open $infile for reading");
	open( my $out_fh, '>', $outfile ) || $logger->error("Can't open $outfile for writing");
	while (<$in_fh>) {
		next if $_ =~ /^\#/x;
		print $out_fh $_;
	}
	close $in_fh;
	close $out_fh;
	return;
}

sub _data_linked_to_locus {
	my ( $self, $locus, $table ) = @_;    #Locus is value defined in drop-down box - may be a scheme or 0 for all loci.
	my $qry;
	my $values = [];
	if ( $locus eq '0' ) {
		$qry = "SELECT EXISTS (SELECT * FROM $table)";
	} elsif ( $locus =~ /SCHEME_(\d+)/x ) {
		$qry = "SELECT EXISTS (SELECT * FROM $table WHERE locus IN (SELECT locus FROM "
		  . 'scheme_members WHERE scheme_id=?))';
		push @$values, $1;
	} elsif ( $locus =~ /GROUP_(\d+)/x ) {
		my $set_id = $self->get_set_id;
		my $group_schemes = $self->{'datastore'}->get_schemes_in_group( $1, { set_id => $set_id } );
		local $" = ',';
		$qry = "SELECT EXISTS (SELECT * FROM $table WHERE locus IN (SELECT locus FROM scheme_members WHERE scheme_id "
		  . "IN (@$group_schemes)))";
	} else {
		$qry = "SELECT EXISTS (SELECT * FROM $table WHERE locus=?)";
		push @$values, $locus;
	}
	return $self->{'datastore'}->run_query( $qry, $values );
}
1;
