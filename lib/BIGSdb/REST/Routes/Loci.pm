#Written by Keith Jolley
#Copyright (c) 2014-2015, University of Oxford
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
package BIGSdb::REST::Routes::Loci;
use strict;
use warnings;
use 5.010;
use POSIX qw(ceil);
use JSON;
use Dancer2 appname => 'BIGSdb::REST::Interface';

#Locus routes
get '/db/:db/loci'                  => sub { _get_loci() };
get '/db/:db/loci/:locus'           => sub { _get_locus() };
post '/db/:db/loci/:locus/sequence' => sub { _query_locus_sequence() };
post '/db/:db/sequence'             => sub { _query_sequence() };

sub _get_loci {
	my $self   = setting('self');
	my ($db)   = params->{'db'};
	my $page   = ( BIGSdb::Utils::is_int( param('page') ) && param('page') > 0 ) ? param('page') : 1;
	my $set_id = $self->get_set_id;
	my $set_clause =
	  $set_id
	  ? ' WHERE (id IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes '
	  . "WHERE set_id=$set_id)) OR id IN (SELECT locus FROM set_loci WHERE set_id=$set_id))"
	  : '';
	my $locus_count = $self->{'datastore'}->run_query("SELECT COUNT(*) FROM loci$set_clause");
	my $pages       = ceil( $locus_count / $self->{'page_size'} );
	my $offset      = ( $page - 1 ) * $self->{'page_size'};
	my $qry         = "SELECT id FROM loci$set_clause ORDER BY id";
	$qry .= " OFFSET $offset LIMIT $self->{'page_size'}" if !param('return_all');
	my $loci = $self->{'datastore'}->run_query( $qry, undef, { fetch => 'col_arrayref' } );
	my $values = { records => int($locus_count) };

	if (@$loci) {
		my $paging = $self->get_paging( "/db/$db/loci", $pages, $page );
		$values->{'paging'} = $paging if %$paging;
		my @links;
		foreach my $locus (@$loci) {
			my $cleaned_locus = $self->clean_locus($locus);
			push @links, request->uri_for("/db/$db/loci/$cleaned_locus");
		}
		$values->{'loci'} = \@links;
	}
	return $values;
}

sub _get_locus {
	my $self = setting('self');
	my ( $db, $locus ) = ( params->{'db'}, params->{'locus'} );
	my $set_id     = $self->get_set_id;
	my $locus_name = $locus;
	if ($set_id) {
		$locus_name = $self->{'datastore'}->get_set_locus_real_id( $locus, $set_id );
	}
	my $locus_info = $self->{'datastore'}->get_locus_info($locus_name);
	if ( !$locus_info ) {
		send_error( "Locus $locus does not exist.", 404 );
	}
	my $values = {};
	my %boolean_field = map { $_ => 1 } qw(length_varies coding_sequence);
	foreach my $field (
		qw(id data_type allele_id_format allele_id_regex common_name length length_varies min_length max_length
		coding_sequence genome_position orf reference_sequence)
	  )
	{
		if ( $boolean_field{$field} ) {
			$values->{$field} = $locus_info->{$field} ? JSON::true : JSON::false;
		} else {
			$values->{$field} = $locus_info->{$field} if defined $locus_info->{$field};
		}
	}

	#Aliases
	my $aliases = $self->{'datastore'}->run_query( 'SELECT alias FROM locus_aliases WHERE locus=? ORDER BY alias',
		$locus_name, { fetch => 'col_arrayref' } );
	$values->{'aliases'} = $aliases if @$aliases;
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		_get_extended_attributes( $values, $locus_name );
		_get_description( $values, $locus_name );
		_get_curators( $values, $locus_name );
	} else {

		#Isolate databases - attempt to link to seqdef definitions
		my $seqdef_definition = _get_seqdef_definition($locus_name);
		if ($seqdef_definition) {
			$values->{'seqdef_definition'} = request->uri_for($seqdef_definition);
		}
	}
	my $schemes = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	my $scheme_member_list = [];
	foreach my $scheme (@$schemes) {
		my $is_member = $self->{'datastore'}->run_query(
			'SELECT EXISTS(SELECT * FROM scheme_members WHERE (scheme_id,locus)=(?,?))',
			[ $scheme->{'id'}, $locus_name ],
			{ cache => 'Loci::scheme_member' }
		);
		if ($is_member) {
			push @$scheme_member_list,
			  { scheme => request->uri_for("/db/$db/schemes/$scheme->{'id'}"), description => $scheme->{'name'} };
		}
	}
	if (@$scheme_member_list) {
		$values->{'schemes'} = $scheme_member_list;
	}
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		if ( $self->{'datastore'}->sequences_exist($locus_name) ) {
			$values->{'alleles'}       = request->uri_for("/db/$db/loci/$locus_name/alleles");
			$values->{'alleles_fasta'} = request->uri_for("/db/$db/loci/$locus_name/alleles_fasta");
		}
	}
	return $values;
}

sub _query_locus_sequence {
	my $self = setting('self');
	my ( $db, $locus, $sequence ) = ( params->{'db'}, params->{'locus'}, params->{'sequence'} );
	$self->check_seqdef_database;
	my $set_id     = $self->get_set_id;
	my $locus_name = $locus;
	if ($set_id) {
		$locus_name = $self->{'datastore'}->get_set_locus_real_id( $locus, $set_id );
	}
	my $locus_info = $self->{'datastore'}->get_locus_info($locus_name);
	if ( !$locus_info ) {
		send_error( "Locus $locus does not exist.", 404 );
	}
	if ( !$sequence ) {
		send_error( 'Required field missing: sequence.', 400 );
	}
	$sequence =~ s/\s//gx;
	my $matches = $self->{'datastore'}->run_query(
		'SELECT allele_id FROM sequences WHERE (locus,md5(sequence))=(?,md5(?))',
		[ $locus_name, uc($sequence) ],
		{ fetch => 'col_arrayref' }
	);
	my @exacts;
	foreach my $exact (@$matches) {
		push @exacts, { allele_id => $exact, href => request->uri_for("/db/$db/loci/$locus/alleles/$exact") };
	}
	my $values = { exact_matches => \@exacts };
	return $values;
}

sub _query_sequence {
	my $self = setting('self');
	my ( $db, $sequence ) = ( params->{'db'}, params->{'sequence'} );
	$self->check_seqdef_database;
	my $set_id = $self->get_set_id;
	if ( !$sequence ) {
		send_error( 'Required field missing: sequence.', 400 );
	}
	$sequence =~ s/\s//gx;
	my $matches = $self->{'datastore'}->run_query( 'SELECT locus,allele_id FROM sequences WHERE md5(sequence)=md5(?)',
		uc($sequence), { fetch => 'all_arrayref', slice => {} } );
	my @exacts;
	foreach my $exact (@$matches) {
		my $locus_name = $exact->{'locus'};
		if ($set_id) {
			$locus_name = $self->{'datastore'}->get_set_locus_real_id( $exact->{'locus'}, $set_id );
		}
		push @exacts,
		  {
			locus     => $locus_name,
			allele_id => $exact->{'allele_id'},
			href      => request->uri_for("/db/$db/loci/$locus_name/alleles/$exact->{'allele_id'}")
		  };
	}
	my $values = { exact_matches => \@exacts };
	return $values;
}

#We probably need to have a specific field in the loci table to
#define this as there are too many cases where this won't work.
sub _get_seqdef_definition {
	my ($locus)    = @_;
	my $self       = setting('self');
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	foreach my $url (qw(description_url url)) {
		if (
			   $locus_info->{$url}
			&& $locus_info->{$url} =~ /page=(?:locusInfo|alleleInfo)/x
			&& $locus_info->{$url} =~ /^\//x                             #Relative URL so on same server
			&& $locus_info->{$url} =~ /locus=(\w+)/x
		  )
		{
			my $seqdef_locus = $1;
			if ( $locus_info->{$url} =~ /db=(\w+)/x ) {
				my $seqdef_config = $1;
				return "/db/$seqdef_config/loci/$seqdef_locus";
			}
		}
	}
	return;
}

sub _get_extended_attributes {
	my ( $values, $locus_name ) = @_;
	my $self = setting('self');
	my $db   = params->{'db'};
	my $extended_attributes =
	  $self->{'datastore'}
	  ->run_query( 'SELECT * FROM locus_extended_attributes WHERE locus=? ORDER BY field_order,field',
		$locus_name, { fetch => 'all_arrayref', slice => {} } );
	my @attributes;
	foreach my $attribute (@$extended_attributes) {
		my $attribute_list = {};
		foreach (qw(field value_format value_regex description length)) {
			$attribute_list->{$_} = $attribute->{$_} if defined $attribute->{$_};
		}
		$attribute_list->{'required'} = $attribute->{'required'} ? JSON::true : JSON::false;
		if ( $attribute->{'option_list'} ) {
			my @values = split /\|/x, $attribute->{'option_list'};
			$attribute_list->{'allowed_values'} = \@values;
		}
		push @attributes, $attribute_list;
	}
	$values->{'extended_attributes'} = \@attributes if @attributes;
	return;
}

sub _get_description {
	my ( $values, $locus_name ) = @_;
	my $self = setting('self');
	my $db   = params->{'db'};
	my $description =
	  $self->{'datastore'}
	  ->run_query( 'SELECT * FROM locus_descriptions WHERE locus=?', $locus_name, { fetch => 'row_hashref' } );
	foreach (qw(full_name product description)) {
		$values->{$_} = $description->{$_} if defined $description->{$_} && $description->{$_} ne '';
	}
	my $pubmed_ids =
	  $self->{'datastore'}->run_query( 'SELECT pubmed_id FROM locus_refs WHERE locus=? ORDER BY pubmed_id',
		$locus_name, { fetch => 'col_arrayref' } );
	$values->{'publications'} = $pubmed_ids if @$pubmed_ids;
	return;
}

sub _get_curators {
	my ( $values, $locus_name ) = @_;
	my $self = setting('self');
	my $db   = params->{'db'};
	my $curators =
	  $self->{'datastore'}->run_query( 'SELECT curator_id FROM locus_curators WHERE locus=? ORDER BY curator_id',
		$locus_name, { fetch => 'col_arrayref' } );
	my @curator_links;
	foreach my $user_id (@$curators) {
		push @curator_links, request->uri_for("/db/$db/users/$user_id");
	}
	$values->{'curators'} = \@curator_links if @curator_links;
	return;
}
1;
