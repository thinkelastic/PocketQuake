/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// r_edge.c

#include "quakedef.h"
#include "r_local.h"
#include "libc.h"
#include "scanline_accel.h"

/* Sub-profiling for R_ScanEdges breakdown */
unsigned int pq_prof_se_insert_cycles;
unsigned int pq_prof_se_generate_cycles;
unsigned int pq_prof_se_step_cycles;
unsigned int pq_prof_se_draw_cycles;
unsigned int pq_prof_hw_spans_total;
unsigned int pq_prof_hw_spans_linked;
unsigned int pq_dbg_hw_nspans;
unsigned int pq_dbg_hw_raw[3];
unsigned int pq_dbg_hw_edges;
unsigned int pq_dbg_hw_first_edge;
unsigned int pq_dbg_hw_state;
unsigned int pq_dbg_hw_edges_reg;
static int pq_dbg_hw_captured;
extern cvar_t pq_cycleprof;

#if 0
// FIXME
the complex cases add new polys on most lines, so dont optimize for keeping them the same
have multiple free span lists to try to get better coherence?
low depth complexity -- 1 to 3 or so

this breaks spans at every edge, even hidden ones (bad)

have a sentinal at both ends?
#endif


edge_t	*auxedges;
edge_t	*r_edges, *edge_p, *edge_max;

surf_t	*surfaces, *surface_p, *surf_max;

// surfaces are generated in back to front order by the bsp, so if a surf
// pointer is greater than another one, it should be drawn in front
// surfaces[1] is the background, and is used as the active surface stack

edge_t	*newedges[MAXHEIGHT];
edge_t	*removeedges[MAXHEIGHT];

espan_t	*span_p, *max_span_p;

int		r_currentkey;

extern	int	screenwidth;

int	current_iv;

int	edge_head_u_shift20, edge_tail_u_shift20;

static void (*pdrawfunc)(void);
static void (*pdrawfunc_array)(void);

edge_t	edge_head;
edge_t	edge_tail;
edge_t	edge_aftertail;
edge_t	edge_sentinel;

float	fv;

/*
==============
Array-based Active Edge Table (AET)
Contiguous sorted array of 16-byte entries replaces linked-list AET.
==============
*/
typedef struct {
	fixed16_t       u;          // 12.20 fixed-point x position
	fixed16_t       u_step;     // per-scanline x step
	unsigned short  surfs[2];   // surface indices [0]=trailing [1]=leading
	unsigned short  v_end;      // last scanline this edge is active
	unsigned short  pad;        // pad to 16 bytes
} aet_entry_t;

static aet_entry_t aet[NUMSTACKEDGES];
static int aet_count;

// Store v_end in edge_t->prev (unused by array-based AET, same cache line as u/surfs)
#define EDGE_V_END(e)  (*(unsigned short *)&(e)->prev)

void R_GenerateSpans (void);
void R_GenerateSpansBackward (void);

void R_LeadingEdge (edge_t *edge);
void R_LeadingEdgeBackwards (edge_t *edge);
void R_TrailingEdge (surf_t *surf, edge_t *edge);

// Array-based AET functions
void R_InsertNewEdges_Array (edge_t *edgestoadd);
void R_RemoveEdges_Array (int iv);
void R_StepActiveU_Array (void);
void R_GenerateSpans_Array (void);
void R_GenerateSpansBackward_Array (void);
void R_TrailingEdge_A (surf_t *surf, int u);
void R_LeadingEdge_A (int surf_idx, int u);
void R_LeadingEdgeBackwards_A (int surf_idx, int u);


//=============================================================================


/*
==============
R_DrawCulledPolys
==============
*/
void R_DrawCulledPolys (void)
{
	surf_t			*s;
	msurface_t		*pface;

	currententity = &cl_entities[0];

	if (r_worldpolysbacktofront)
	{
		for (s=surface_p-1 ; s>&surfaces[1] ; s--)
		{
			if (!s->spans)
				continue;

			if (!(s->flags & SURF_DRAWBACKGROUND))
			{
				pface = (msurface_t *)s->data;
				R_RenderPoly (pface, 15);
			}
		}
	}
	else
	{
		for (s = &surfaces[1] ; s<surface_p ; s++)
		{
			if (!s->spans)
				continue;

			if (!(s->flags & SURF_DRAWBACKGROUND))
			{
				pface = (msurface_t *)s->data;
				R_RenderPoly (pface, 15);
			}
		}
	}
}


/*
==============
R_BeginEdgeFrame
==============
*/
PQ_FASTTEXT void R_BeginEdgeFrame (void)
{
	int		v;

	edge_p = r_edges;
	edge_max = &r_edges[r_numallocatededges];

	surface_p = &surfaces[2];	// background is surface 1,
								//  surface 0 is a dummy
	surfaces[1].spans = NULL;	// no background spans yet
	surfaces[1].flags = SURF_DRAWBACKGROUND;

// put the background behind everything in the world
	if (r_draworder.value)
	{
		pdrawfunc = R_GenerateSpansBackward;
		pdrawfunc_array = R_GenerateSpansBackward_Array;
		surfaces[1].key = 0;
		r_currentkey = 1;
	}
	else
	{
		pdrawfunc = R_GenerateSpans;
		pdrawfunc_array = R_GenerateSpans_Array;
		surfaces[1].key = 0x7FFFFFFF;
		r_currentkey = 0;
	}

	{
		int height = r_refdef.vrectbottom - r_refdef.vrect.y;
		memset (&newedges[r_refdef.vrect.y], 0, height * sizeof(edge_t *));
		memset (&removeedges[r_refdef.vrect.y], 0, height * sizeof(edge_t *));
	}
}


#if	!id386

/*
==============
R_InsertNewEdges

Adds the edges in the linked list edgestoadd, adding them to the edges in the
linked list edgelist.  edgestoadd is assumed to be sorted on u, and non-empty (this is actually newedges[v]).  edgelist is assumed to be sorted on u, with a
sentinel at the end (actually, this is the active edge table starting at
edge_head.next).
==============
*/
PQ_FASTTEXT void R_InsertNewEdges (edge_t *edgestoadd, edge_t *edgelist)
{
	edge_t	*next_edge;

	do
	{
		next_edge = edgestoadd->next;
	edgesearch:
		if (edgelist->u >= edgestoadd->u)
			goto addedge;
		edgelist=edgelist->next;
		if (edgelist->u >= edgestoadd->u)
			goto addedge;
		edgelist=edgelist->next;
		if (edgelist->u >= edgestoadd->u)
			goto addedge;
		edgelist=edgelist->next;
		if (edgelist->u >= edgestoadd->u)
			goto addedge;
		edgelist=edgelist->next;
		goto edgesearch;

	// insert edgestoadd before edgelist
addedge:
		edgestoadd->next = edgelist;
		edgestoadd->prev = edgelist->prev;
		edgelist->prev->next = edgestoadd;
		edgelist->prev = edgestoadd;
	} while ((edgestoadd = next_edge) != NULL);
}

#endif	// !id386
	

#if	!id386

/*
==============
R_RemoveEdges
==============
*/
PQ_FASTTEXT void R_RemoveEdges (edge_t *pedge)
{

	do
	{
		pedge->next->prev = pedge->prev;
		pedge->prev->next = pedge->next;
	} while ((pedge = pedge->nextremove) != NULL);
}

#endif	// !id386


#if	!id386

/*
==============
R_StepActiveU
==============
*/
PQ_FASTTEXT void R_StepActiveU (edge_t *pedge)
{
	edge_t		*pnext_edge, *pwedge;

	while (1)
	{
	nextedge:
		pedge->u += pedge->u_step;
		if (pedge->u < pedge->prev->u)
			goto pushback;
		pedge = pedge->next;
			
		pedge->u += pedge->u_step;
		if (pedge->u < pedge->prev->u)
			goto pushback;
		pedge = pedge->next;
			
		pedge->u += pedge->u_step;
		if (pedge->u < pedge->prev->u)
			goto pushback;
		pedge = pedge->next;
			
		pedge->u += pedge->u_step;
		if (pedge->u < pedge->prev->u)
			goto pushback;
		pedge = pedge->next;
			
		goto nextedge;		
		
pushback:
		if (pedge == &edge_aftertail)
			return;
			
	// push it back to keep it sorted		
		pnext_edge = pedge->next;

	// pull the edge out of the edge list
		pedge->next->prev = pedge->prev;
		pedge->prev->next = pedge->next;

		// find out where the edge goes in the edge list
		pwedge = pedge->prev->prev;
		while (pwedge->u > pedge->u)
			pwedge = pwedge->prev;

	// put the edge back into the edge list
		pedge->next = pwedge->next;
		pedge->prev = pwedge;
		pedge->next->prev = pedge;
		pwedge->next = pedge;

		pedge = pnext_edge;
		if (pedge == &edge_tail)
			return;
	}
}

#endif	// !id386


/*
==============
R_CleanupSpan
==============
*/
PQ_FASTTEXT void R_CleanupSpan ()
{
	surf_t	*surf;
	int		iu;
	espan_t	*span;

// now that we've reached the right edge of the screen, we're done with any
// unfinished surfaces, so emit a span for whatever's on top
	surf = surfaces[1].next;
	iu = edge_tail_u_shift20;
	if (iu > surf->last_u)
	{
		span = span_p++;
		span->u = surf->last_u;
		span->count = iu - span->u;
		span->v = current_iv;
		span->pnext = surf->spans;
		surf->spans = span;
	}

// reset spanstate for all surfaces in the surface stack
	do
	{
		surf->spanstate = 0;
		surf = surf->next;
	} while (surf != &surfaces[1]);
}


/*
==============
R_LeadingEdgeBackwards
==============
*/
PQ_FASTTEXT void R_LeadingEdgeBackwards (edge_t *edge)
{
	espan_t			*span;
	surf_t			*surf, *surf2;
	int				iu;

// it's adding a new surface in, so find the correct place
	surf = &surfaces[edge->surfs[1]];

// don't start a span if this is an inverted span, with the end
// edge preceding the start edge (that is, we've already seen the
// end edge)
	if (++surf->spanstate == 1)
	{
		surf2 = surfaces[1].next;

		if (surf->key > surf2->key)
			goto newtop;

	// if it's two surfaces on the same plane, the one that's already
	// active is in front, so keep going unless it's a bmodel
		if (surf->insubmodel && (surf->key == surf2->key))
		{
		// must be two bmodels in the same leaf; don't care, because they'll
		// never be farthest anyway
			goto newtop;
		}

continue_search:

		do
		{
			surf2 = surf2->next;
		} while (surf->key < surf2->key);

		if (surf->key == surf2->key)
		{
		// if it's two surfaces on the same plane, the one that's already
		// active is in front, so keep going unless it's a bmodel
			if (!surf->insubmodel)
				goto continue_search;

		// must be two bmodels in the same leaf; don't care which is really
		// in front, because they'll never be farthest anyway
		}

		goto gotposition;

newtop:
	// emit a span (obscures current top)
		iu = edge->u >> 20;

		if (iu > surf2->last_u)
		{
			span = span_p++;
			span->u = surf2->last_u;
			span->count = iu - span->u;
			span->v = current_iv;
			span->pnext = surf2->spans;
			surf2->spans = span;
		}

		// set last_u on the new span
		surf->last_u = iu;
				
gotposition:
	// insert before surf2
		surf->next = surf2;
		surf->prev = surf2->prev;
		surf2->prev->next = surf;
		surf2->prev = surf;
	}
}


/*
==============
R_TrailingEdge
==============
*/
PQ_FASTTEXT void R_TrailingEdge (surf_t *surf, edge_t *edge)
{
	espan_t			*span;
	int				iu;

// don't generate a span if this is an inverted span, with the end
// edge preceding the start edge (that is, we haven't seen the
// start edge yet)
	if (--surf->spanstate == 0)
	{
		if (surf->insubmodel)
			r_bmodelactive--;

		if (surf == surfaces[1].next)
		{
		// emit a span (current top going away)
			iu = edge->u >> 20;
			if (iu > surf->last_u)
			{
				span = span_p++;
				span->u = surf->last_u;
				span->count = iu - span->u;
				span->v = current_iv;
				span->pnext = surf->spans;
				surf->spans = span;
			}

		// set last_u on the surface below
			surf->next->last_u = iu;
		}

		surf->prev->next = surf->next;
		surf->next->prev = surf->prev;
	}
}


#if	!id386

/*
==============
R_LeadingEdge
==============
*/
PQ_FASTTEXT void R_LeadingEdge (edge_t *edge)
{
	espan_t			*span;
	surf_t			*surf, *surf2;
	int				iu;
	float			fu, newzi, testzi, newzitop, newzibottom;

	if (edge->surfs[1])
	{
	// it's adding a new surface in, so find the correct place
		surf = &surfaces[edge->surfs[1]];

	// don't start a span if this is an inverted span, with the end
	// edge preceding the start edge (that is, we've already seen the
	// end edge)
		if (++surf->spanstate == 1)
		{
			if (surf->insubmodel)
				r_bmodelactive++;

			surf2 = surfaces[1].next;

			if (surf->key < surf2->key)
				goto newtop;

		// if it's two surfaces on the same plane, the one that's already
		// active is in front, so keep going unless it's a bmodel
			if (surf->insubmodel && (surf->key == surf2->key))
			{
			// must be two bmodels in the same leaf; sort on 1/z
				fu = (float)(edge->u - 0xFFFFF) * (1.0 / 0x100000);
				newzi = surf->d_ziorigin + fv*surf->d_zistepv +
						fu*surf->d_zistepu;
				newzibottom = newzi * 0.99;

				testzi = surf2->d_ziorigin + fv*surf2->d_zistepv +
						fu*surf2->d_zistepu;

				if (newzibottom >= testzi)
				{
					goto newtop;
				}

				newzitop = newzi * 1.01;
				if (newzitop >= testzi)
				{
					if (surf->d_zistepu >= surf2->d_zistepu)
					{
						goto newtop;
					}
				}
			}

continue_search:

			do
			{
				surf2 = surf2->next;
			} while (surf->key > surf2->key);

			if (surf->key == surf2->key)
			{
			// if it's two surfaces on the same plane, the one that's already
			// active is in front, so keep going unless it's a bmodel
				if (!surf->insubmodel)
					goto continue_search;

			// must be two bmodels in the same leaf; sort on 1/z
				fu = (float)(edge->u - 0xFFFFF) * (1.0 / 0x100000);
				newzi = surf->d_ziorigin + fv*surf->d_zistepv +
						fu*surf->d_zistepu;
				newzibottom = newzi * 0.99;

				testzi = surf2->d_ziorigin + fv*surf2->d_zistepv +
						fu*surf2->d_zistepu;

				if (newzibottom >= testzi)
				{
					goto gotposition;
				}

				newzitop = newzi * 1.01;
				if (newzitop >= testzi)
				{
					if (surf->d_zistepu >= surf2->d_zistepu)
					{
						goto gotposition;
					}
				}

				goto continue_search;
			}

			goto gotposition;

newtop:
		// emit a span (obscures current top)
			iu = edge->u >> 20;

			if (iu > surf2->last_u)
			{
				span = span_p++;
				span->u = surf2->last_u;
				span->count = iu - span->u;
				span->v = current_iv;
				span->pnext = surf2->spans;
				surf2->spans = span;
			}

			// set last_u on the new span
			surf->last_u = iu;
				
gotposition:
		// insert before surf2
			surf->next = surf2;
			surf->prev = surf2->prev;
			surf2->prev->next = surf;
			surf2->prev = surf;
		}
	}
}


/*
==============
R_GenerateSpans
==============
*/
PQ_FASTTEXT void R_GenerateSpans (void)
{
	edge_t			*edge;
	surf_t			*surf;

	r_bmodelactive = 0;

// clear active surfaces to just the background surface
	surfaces[1].next = surfaces[1].prev = &surfaces[1];
	surfaces[1].last_u = edge_head_u_shift20;

// generate spans
	for (edge=edge_head.next ; edge != &edge_tail; edge=edge->next)
	{			
		if (edge->surfs[0])
		{
		// it has a left surface, so a surface is going away for this span
			surf = &surfaces[edge->surfs[0]];

			R_TrailingEdge (surf, edge);

			if (!edge->surfs[1])
				continue;
		}

		R_LeadingEdge (edge);
	}

	R_CleanupSpan ();
}

#endif	// !id386


/*
==============
R_GenerateSpansBackward
==============
*/
PQ_FASTTEXT void R_GenerateSpansBackward (void)
{
	edge_t			*edge;

	r_bmodelactive = 0;

// clear active surfaces to just the background surface
	surfaces[1].next = surfaces[1].prev = &surfaces[1];
	surfaces[1].last_u = edge_head_u_shift20;

// generate spans
	for (edge=edge_head.next ; edge != &edge_tail; edge=edge->next)
	{			
		if (edge->surfs[0])
			R_TrailingEdge (&surfaces[edge->surfs[0]], edge);

		if (edge->surfs[1])
			R_LeadingEdgeBackwards (edge);
	}

	R_CleanupSpan ();
}


/*
==============================================================================
Array-based AET functions
==============================================================================
*/

/*
==============
R_InsertNewEdges_Array

Merge sorted newedges linked list into sorted aet[] array.
==============
*/
PQ_FASTTEXT void R_InsertNewEdges_Array (edge_t *edgestoadd)
{
	edge_t *rev, *next;
	int new_count, i, k;

	// Reverse linked list to get descending u order for right-to-left merge.
	// newedges[iv] is only traversed here, so in-place reversal is safe.
	rev = NULL;
	new_count = 0;
	while (edgestoadd)
	{
		next = edgestoadd->next;
		edgestoadd->next = rev;
		rev = edgestoadd;
		new_count++;
		edgestoadd = next;
	}

	// Right-to-left merge: aet[0..aet_count-1] ascending, rev list descending.
	// Merge into aet[0..aet_count+new_count-1]. No temp buffer needed.
	i = aet_count - 1;
	k = aet_count + new_count - 1;

	while (rev)
	{
		if (i >= 0 && aet[i].u > rev->u)
		{
			aet[k--] = aet[i--];
		}
		else
		{
			aet[k].u       = rev->u;
			aet[k].u_step  = rev->u_step;
			aet[k].surfs[0] = rev->surfs[0];
			aet[k].surfs[1] = rev->surfs[1];
			aet[k].v_end   = EDGE_V_END(rev);
			k--;
			rev = rev->next;
		}
	}

	aet_count += new_count;
}


/*
==============
R_RemoveEdges_Array

Compact out entries whose v_end == current scanline.
==============
*/
PQ_FASTTEXT void R_RemoveEdges_Array (int iv)
{
	int i, j;

	for (i = 0, j = 0; i < aet_count; i++)
	{
		if (aet[i].v_end != iv)
		{
			if (i != j)
				aet[j] = aet[i];
			j++;
		}
	}
	aet_count = j;
}


/*
==============
R_StepActiveU_Array

Step all u values, then insertion sort (nearly sorted -> ~O(n)).
==============
*/
PQ_FASTTEXT void R_StepActiveU_Array (void)
{
	int i;

	// Step
	for (i = 0; i < aet_count; i++)
		aet[i].u += aet[i].u_step;

	// Insertion sort (nearly sorted, few swaps expected)
	for (i = 1; i < aet_count; i++)
	{
		if (aet[i].u < aet[i-1].u)
		{
			aet_entry_t tmp = aet[i];
			int j = i - 1;
			while (j >= 0 && aet[j].u > tmp.u)
			{
				aet[j+1] = aet[j];
				j--;
			}
			aet[j+1] = tmp;
		}
	}
}


/*
==============
R_TrailingEdge_A

Array variant: takes surface pointer and u value directly.
==============
*/
PQ_FASTTEXT void R_TrailingEdge_A (surf_t *surf, int u)
{
	espan_t		*span;
	int			iu;

	if (--surf->spanstate == 0)
	{
		if (surf->insubmodel)
			r_bmodelactive--;

		if (surf == surfaces[1].next)
		{
			iu = u >> 20;
			if (iu > surf->last_u)
			{
				span = span_p++;
				span->u = surf->last_u;
				span->count = iu - span->u;
				span->v = current_iv;
				span->pnext = surf->spans;
				surf->spans = span;
			}

			surf->next->last_u = iu;
		}

		surf->prev->next = surf->next;
		surf->next->prev = surf->prev;
	}
}


/*
==============
R_LeadingEdge_A

Array variant: takes surface index and u value directly.
==============
*/
PQ_FASTTEXT void R_LeadingEdge_A (int surf_idx, int u)
{
	espan_t		*span;
	surf_t		*surf, *surf2;
	int			iu;
	float		fu, newzi, testzi, newzitop, newzibottom;

	if (surf_idx)
	{
		surf = &surfaces[surf_idx];

		if (++surf->spanstate == 1)
		{
			if (surf->insubmodel)
				r_bmodelactive++;

			surf2 = surfaces[1].next;

			if (surf->key < surf2->key)
				goto newtop;

			if (surf->insubmodel && (surf->key == surf2->key))
			{
				fu = (float)(u - 0xFFFFF) * (1.0 / 0x100000);
				newzi = surf->d_ziorigin + fv*surf->d_zistepv +
						fu*surf->d_zistepu;
				newzibottom = newzi * 0.99;

				testzi = surf2->d_ziorigin + fv*surf2->d_zistepv +
						fu*surf2->d_zistepu;

				if (newzibottom >= testzi)
					goto newtop;

				newzitop = newzi * 1.01;
				if (newzitop >= testzi)
				{
					if (surf->d_zistepu >= surf2->d_zistepu)
						goto newtop;
				}
			}

continue_search:
			do
			{
				surf2 = surf2->next;
			} while (surf->key > surf2->key);

			if (surf->key == surf2->key)
			{
				if (!surf->insubmodel)
					goto continue_search;

				fu = (float)(u - 0xFFFFF) * (1.0 / 0x100000);
				newzi = surf->d_ziorigin + fv*surf->d_zistepv +
						fu*surf->d_zistepu;
				newzibottom = newzi * 0.99;

				testzi = surf2->d_ziorigin + fv*surf2->d_zistepv +
						fu*surf2->d_zistepu;

				if (newzibottom >= testzi)
					goto gotposition;

				newzitop = newzi * 1.01;
				if (newzitop >= testzi)
				{
					if (surf->d_zistepu >= surf2->d_zistepu)
						goto gotposition;
				}

				goto continue_search;
			}

			goto gotposition;

newtop:
			iu = u >> 20;

			if (iu > surf2->last_u)
			{
				span = span_p++;
				span->u = surf2->last_u;
				span->count = iu - span->u;
				span->v = current_iv;
				span->pnext = surf2->spans;
				surf2->spans = span;
			}

			surf->last_u = iu;

gotposition:
			surf->next = surf2;
			surf->prev = surf2->prev;
			surf2->prev->next = surf;
			surf2->prev = surf;
		}
	}
}


/*
==============
R_LeadingEdgeBackwards_A

Array variant: takes surface index and u value directly.
==============
*/
PQ_FASTTEXT void R_LeadingEdgeBackwards_A (int surf_idx, int u)
{
	espan_t		*span;
	surf_t		*surf, *surf2;
	int			iu;

	surf = &surfaces[surf_idx];

	if (++surf->spanstate == 1)
	{
		surf2 = surfaces[1].next;

		if (surf->key > surf2->key)
			goto newtop;

		if (surf->insubmodel && (surf->key == surf2->key))
			goto newtop;

continue_search:
		do
		{
			surf2 = surf2->next;
		} while (surf->key < surf2->key);

		if (surf->key == surf2->key)
		{
			if (!surf->insubmodel)
				goto continue_search;
		}

		goto gotposition;

newtop:
		iu = u >> 20;

		if (iu > surf2->last_u)
		{
			span = span_p++;
			span->u = surf2->last_u;
			span->count = iu - span->u;
			span->v = current_iv;
			span->pnext = surf2->spans;
			surf2->spans = span;
		}

		surf->last_u = iu;

gotposition:
		surf->next = surf2;
		surf->prev = surf2->prev;
		surf2->prev->next = surf;
		surf2->prev = surf;
	}
}


#if HW_SCANLINE_ACCEL
/*
==============
R_GenerateSpans_HW

Feed sorted AET edges to hardware scanline engine, read back spans.
==============
*/
PQ_FASTTEXT void R_GenerateSpans_HW (void)
{
	int i;
	int hw_count;

	r_bmodelactive = 0;

	// Cap to edge buffer size (256 entries)
	hw_count = aet_count;
	if (hw_count > 256)
		hw_count = 256;

	// Write edge count (also resets HW edge buffer write pointer)
	SCAN_EDGE_COUNT = hw_count;

	// Feed all AET edges to hardware
	for (i = 0; i < hw_count; i++) {
		int iu = aet[i].u >> 20;
		// Clamp to valid range — negative u from edge stepping would
		// produce garbage in the unsigned 9-bit iu field
		if (iu < 0) iu = 0;
		else if (iu > 511) iu = 511;
		SCAN_EDGE_DATA = ((unsigned int)iu << 23) |
		                 ((unsigned int)aet[i].surfs[1] << 10) |
		                 (unsigned int)aet[i].surfs[0];
	}

	// Start processing (bit 0 = start, bit 1 = backward mode)
	SCAN_CONTROL = r_draworder.value ? 0x3 : 0x1;
	scanline_wait();

	// Read span results from hardware
	{
		int nspans = SCAN_SPAN_COUNT;
		int max_si = surface_p - surfaces;
		int do_capture = (!pq_dbg_hw_captured && hw_count > 0);
		pq_prof_hw_spans_total += nspans;

		if (do_capture) {
			pq_dbg_hw_captured = 1;
			pq_dbg_hw_nspans = nspans;
			pq_dbg_hw_edges = hw_count;
			pq_dbg_hw_first_edge = SCAN_DBG_FIRST_EDGE;
			pq_dbg_hw_state = SCAN_DBG_STATE;
			pq_dbg_hw_edges_reg = SCAN_DBG_EDGES;
		}

		if (nspans > 512)
			nspans = 0;  // garbage — HW not responding correctly
		for (i = 0; i < nspans; i++) {
			unsigned int hw = SCAN_SPAN_DATA;
			int si  = hw & 0x3FF;
			int u   = (hw >> 10) & 0x3FF;
			int cnt = (hw >> 20) & 0x3FF;

			if (do_capture && i < 3)
				pq_dbg_hw_raw[i] = hw;

			if (si < 1 || si >= max_si || cnt == 0)
				continue;  // skip invalid spans
			{
				espan_t *span = span_p++;
				span->u = u;
				span->count = cnt;
				span->v = current_iv;
				span->pnext = surfaces[si].spans;
				surfaces[si].spans = span;
				pq_prof_hw_spans_linked++;
			}
		}
	}
}
#endif


/*
==============
R_GenerateSpans_Array

Walk sorted aet[] array instead of linked list.
==============
*/
PQ_FASTTEXT void R_GenerateSpans_Array (void)
{
	int i;

	r_bmodelactive = 0;

	surfaces[1].next = surfaces[1].prev = &surfaces[1];
	surfaces[1].last_u = edge_head_u_shift20;

	for (i = 0; i < aet_count; i++)
	{
		if (aet[i].surfs[0])
		{
			R_TrailingEdge_A (&surfaces[aet[i].surfs[0]], aet[i].u);

			if (!aet[i].surfs[1])
				continue;
		}

		R_LeadingEdge_A (aet[i].surfs[1], aet[i].u);
	}

	R_CleanupSpan ();
}


/*
==============
R_GenerateSpansBackward_Array

Walk sorted aet[] array instead of linked list (backward variant).
==============
*/
PQ_FASTTEXT void R_GenerateSpansBackward_Array (void)
{
	int i;

	r_bmodelactive = 0;

	surfaces[1].next = surfaces[1].prev = &surfaces[1];
	surfaces[1].last_u = edge_head_u_shift20;

	for (i = 0; i < aet_count; i++)
	{
		if (aet[i].surfs[0])
			R_TrailingEdge_A (&surfaces[aet[i].surfs[0]], aet[i].u);

		if (aet[i].surfs[1])
			R_LeadingEdgeBackwards_A (aet[i].surfs[1], aet[i].u);
	}

	R_CleanupSpan ();
}


/*
==============
R_ScanEdges

Input:
newedges[] array
	this has links to edges, which have links to surfaces

Output:
Each surface has a linked list of its visible spans
==============
*/

PQ_FASTTEXT void R_ScanEdges (void)
{
	int		iv, bottom;
	byte	basespans[MAXSPANS*sizeof(espan_t)+CACHE_SIZE];
	espan_t	*basespan_p;
	surf_t	*s;
	int profiling = (int)pq_cycleprof.value;
	unsigned int prof_t;

	if (profiling) {
		pq_prof_se_insert_cycles = 0;
		pq_prof_se_generate_cycles = 0;
		pq_prof_se_step_cycles = 0;
		pq_prof_se_draw_cycles = 0;
		pq_prof_hw_spans_total = 0;
		pq_prof_hw_spans_linked = 0;
	}

	basespan_p = (espan_t *)
			((long)(basespans + CACHE_SIZE - 1) & ~(CACHE_SIZE - 1));
	max_span_p = &basespan_p[MAXSPANS - r_refdef.vrect.width];

	span_p = basespan_p;

// set up background edge u values (used by R_CleanupSpan and GenerateSpans)
	edge_head.u = r_refdef.vrect.x << 20;
	edge_head_u_shift20 = edge_head.u >> 20;
	edge_tail.u = (r_refdef.vrectright << 20) + 0xFFFFF;
	edge_tail_u_shift20 = edge_tail.u >> 20;

// clear array-based AET
	aet_count = 0;

#if HW_SCANLINE_ACCEL
// Frame setup: clear HW spanstate BRAM and load surface keys
	SCAN_FRAME_INIT = 1;
	scanline_wait();
	for (s = &surfaces[1] ; s<surface_p ; s++)
		scanline_load_surface(s - surfaces, s->key, s->insubmodel);
	SCAN_EDGE_HEAD_U = edge_head_u_shift20;
	SCAN_EDGE_TAIL_U = edge_tail_u_shift20;
	// Debug: read scanline regs (now at 0x60, no ATM collision)
	pq_dbg_hw_state = SCAN_STATUS;
	pq_dbg_hw_edges_reg = SCAN_DBG_EDGES;
	pq_dbg_hw_first_edge = SCAN_DBG_FIRST_EDGE;
#endif

//
// process all scan lines
//
	bottom = r_refdef.vrectbottom - 1;

	for (iv=r_refdef.vrect.y ; iv<bottom ; iv++)
	{
		current_iv = iv;
		fv = (float)iv;

	// mark that the head (background start) span is pre-included
		surfaces[1].spanstate = 1;

		if (newedges[iv])
		{
			if (profiling) prof_t = SYS_CYCLE_LO;
			R_InsertNewEdges_Array (newedges[iv]);
			if (profiling) pq_prof_se_insert_cycles += SYS_CYCLE_LO - prof_t;
		}

		if (profiling) prof_t = SYS_CYCLE_LO;
#if HW_SCANLINE_ACCEL
		R_GenerateSpans_HW ();
#else
		(*pdrawfunc_array) ();
#endif
		if (profiling) pq_prof_se_generate_cycles += SYS_CYCLE_LO - prof_t;

	// flush the span list if we can't be sure we have enough spans left for
	// the next scan
		if (span_p >= max_span_p)
		{
			if (profiling) prof_t = SYS_CYCLE_LO;

			if (r_drawculledpolys)
				R_DrawCulledPolys ();
			else
				D_DrawSurfaces ();

			if (profiling) pq_prof_se_draw_cycles += SYS_CYCLE_LO - prof_t;

		// clear the surface span pointers
			for (s = &surfaces[1] ; s<surface_p ; s++)
				s->spans = NULL;

			span_p = basespan_p;
		}

		R_RemoveEdges_Array (iv);

		if (profiling) prof_t = SYS_CYCLE_LO;
		if (aet_count > 0)
			R_StepActiveU_Array ();
		if (profiling) pq_prof_se_step_cycles += SYS_CYCLE_LO - prof_t;
	}

// do the last scan (no need to step or sort or remove on the last scan)

	current_iv = iv;
	fv = (float)iv;

// mark that the head (background start) span is pre-included
	surfaces[1].spanstate = 1;

	if (newedges[iv])
		R_InsertNewEdges_Array (newedges[iv]);

#if HW_SCANLINE_ACCEL
	R_GenerateSpans_HW ();
#else
	(*pdrawfunc_array) ();
#endif

// draw whatever's left in the span list
	if (r_drawculledpolys)
		R_DrawCulledPolys ();
	else
		D_DrawSurfaces ();
}
