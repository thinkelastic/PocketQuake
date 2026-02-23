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
// r_main.c

#include "quakedef.h"
#include "r_local.h"
#include "d_local.h"
#include "libc.h"

#define SYS_DISPLAY_MODE (*(volatile unsigned int *)0x4000000C)

//define	PASSAGES

void		*colormap;
vec3_t		viewlightvec;
alight_t	r_viewlighting = {128, 192, viewlightvec};
float		r_time1;
int			r_numallocatededges;
qboolean	r_drawpolys;
qboolean	r_drawculledpolys;
qboolean	r_worldpolysbacktofront;
qboolean	r_recursiveaffinetriangles = false;
int			r_pixbytes = 1;
float		r_aliasuvscale = 1.0;
int			r_outofsurfaces;
int			r_outofedges;

qboolean	r_dowarp, r_dowarpold, r_viewchanged;

int			numbtofpolys;
btofpoly_t	*pbtofpolys;
mvertex_t	*r_pcurrentvertbase;

int			c_surf;
int			r_maxsurfsseen, r_maxedgesseen, r_cnumsurfs;
qboolean	r_surfsonstack;
int			r_clipflags;

byte		*r_warpbuffer;

byte		*r_stack_start;

qboolean	r_fov_greater_than_90;

//
// view origin
//
vec3_t	vup, base_vup;
vec3_t	vpn, base_vpn;
vec3_t	vright, base_vright;
vec3_t	r_origin;

//
// screen size info
//
refdef_t	r_refdef;
float		xcenter, ycenter;
float		xscale, yscale;
float		xscaleinv, yscaleinv;
float		xscaleshrink, yscaleshrink;
float		aliasxscale, aliasyscale, aliasxcenter, aliasycenter;

int		screenwidth;

float	pixelAspect;
float	screenAspect;
float	verticalFieldOfView;
float	xOrigin, yOrigin;

mplane_t	screenedge[4];

//
// refresh flags
//
int		r_framecount = 1;	// so frame counts initialized to 0 don't match
int		r_visframecount;
int		d_spanpixcount;
int		r_polycount;
int		r_drawnpolycount;
int		r_wholepolycount;

#define		VIEWMODNAME_LENGTH	256
char		viewmodname[VIEWMODNAME_LENGTH+1];
int			modcount;

int			*pfrustum_indexes[4];
int			r_frustum_indexes[4*6];

int		reinit_surfcache = 1;	// if 1, surface cache is currently empty and
								// must be reinitialized for current cache size

mleaf_t		*r_viewleaf, *r_oldviewleaf;

texture_t	*r_notexture_mip;

float		r_aliastransition, r_resfudge;

int		d_lightstylevalue[256];	// 8.8 fraction of base light value

float	dp_time1, dp_time2, db_time1, db_time2, rw_time1, rw_time2;
float	se_time1, se_time2, de_time1, de_time2, dv_time1, dv_time2;

void R_MarkLeaves (void);

extern unsigned int pq_prof_spans8_cycles_frame;
extern unsigned int pq_prof_spans8_calls_frame;
extern unsigned int pq_prof_zspans_cycles_frame;
extern unsigned int pq_prof_zspans_calls_frame;
static unsigned int pq_prof_alias_cycles_frame;
static unsigned int pq_prof_edge_cycles_frame;
static unsigned int pq_prof_frame_counter;

/* Mode 2: per-frame cycle counters for additional functions */
static unsigned int pq_prof_total_cycles_frame;
static unsigned int pq_prof_setup_cycles_frame;
static unsigned int pq_prof_markleaves_cycles_frame;
static unsigned int pq_prof_zfill_wait_cycles_frame;
static unsigned int pq_prof_entities_cycles_frame;
static unsigned int pq_prof_viewmodel_cycles_frame;
static unsigned int pq_prof_particles_cycles_frame;
static unsigned int pq_prof_warp_cycles_frame;
static unsigned int pq_prof_renderworld_cycles_frame;
static unsigned int pq_prof_scanedges_cycles_frame;
static unsigned int pq_prof_bentities_cycles_frame;

/* Mode 2: 64-frame accumulators */
static unsigned int pq_prof_total_accum;
static unsigned int pq_prof_setup_accum;
static unsigned int pq_prof_markleaves_accum;
static unsigned int pq_prof_zfill_wait_accum;
static unsigned int pq_prof_edge_accum;
static unsigned int pq_prof_entities_accum;
static unsigned int pq_prof_viewmodel_accum;
static unsigned int pq_prof_particles_accum;
static unsigned int pq_prof_warp_accum;
static unsigned int pq_prof_spans8_accum;
static unsigned int pq_prof_zspans_accum;
static unsigned int pq_prof_alias_accum;
static unsigned int pq_prof_spans8_calls_accum;
static unsigned int pq_prof_zspans_calls_accum;
static unsigned int pq_prof_renderworld_accum;
static unsigned int pq_prof_scanedges_accum;
static unsigned int pq_prof_bentities_accum;

/* Mode 2: averaged values (updated every 64 frames) */
static unsigned int pq_prof_avg_total;
static unsigned int pq_prof_avg_setup;
static unsigned int pq_prof_avg_markleaves;
static unsigned int pq_prof_avg_zfill_wait;
static unsigned int pq_prof_avg_edge;
static unsigned int pq_prof_avg_entities;
static unsigned int pq_prof_avg_viewmodel;
static unsigned int pq_prof_avg_particles;
static unsigned int pq_prof_avg_warp;
static unsigned int pq_prof_avg_spans8;
static unsigned int pq_prof_avg_zspans;
static unsigned int pq_prof_avg_alias;
static unsigned int pq_prof_avg_spans8_calls;
static unsigned int pq_prof_avg_zspans_calls;
static unsigned int pq_prof_avg_renderworld;
static unsigned int pq_prof_avg_scanedges;
static unsigned int pq_prof_avg_bentities;

/* Mode tracking for display mode transitions */
static int pq_prof_prev_mode;

cvar_t	r_draworder = {"r_draworder","0"};
cvar_t	r_speeds = {"r_speeds","0"};
cvar_t	r_timegraph = {"r_timegraph","0"};
cvar_t	r_graphheight = {"r_graphheight","10"};
cvar_t	r_clearcolor = {"r_clearcolor","2"};
cvar_t	r_fastsky = {"r_fastsky","0"};
cvar_t	r_flatwater = {"r_flatwater","0"};
cvar_t	r_waterwarp = {"r_waterwarp","0"};
cvar_t	r_fullbright = {"r_fullbright","0"};
cvar_t	r_dynamic = {"r_dynamic","0"};
cvar_t	r_drawentities = {"r_drawentities","1"};
cvar_t	r_drawviewmodel = {"r_drawviewmodel","1"};
cvar_t	r_drawparticles = {"r_drawparticles","0"};
cvar_t	r_hwspan = {"r_hwspan","1"};
cvar_t	r_hwzspan = {"r_hwzspan","1"};
cvar_t	r_hwspan_queue = {"r_hwspan_queue","0"};
cvar_t	r_aliasstats = {"r_polymodelstats","0"};
cvar_t	r_dspeeds = {"r_dspeeds","0"};
cvar_t	r_drawflat = {"r_drawflat", "0"};
cvar_t	r_cullsize = {"r_cullsize", "2"};
cvar_t	r_ambient = {"r_ambient", "0"};
cvar_t	r_reportsurfout = {"r_reportsurfout", "0"};
cvar_t	r_maxsurfs = {"r_maxsurfs", "0"};
cvar_t	r_numsurfs = {"r_numsurfs", "0"};
cvar_t	r_reportedgeout = {"r_reportedgeout", "0"};
cvar_t	r_maxedges = {"r_maxedges", "0"};
cvar_t	r_numedges = {"r_numedges", "0"};
cvar_t	r_aliastransbase = {"r_aliastransbase", "200"};
cvar_t	r_aliastransadj = {"r_aliastransadj", "100"};
cvar_t	pq_cycleprof = {"pq_cycleprof", "0"};

extern cvar_t	scr_fov;

void CreatePassages (void);
void SetVisibilityByPassages (void);

/*
==================
R_InitTextures
==================
*/
void	R_InitTextures (void)
{
	int		x,y, m;
	byte	*dest;
	
// create a simple checkerboard texture for the default
	r_notexture_mip = Hunk_AllocName (sizeof(texture_t) + 16*16+8*8+4*4+2*2, "notexture");
	
	r_notexture_mip->width = r_notexture_mip->height = 16;
	r_notexture_mip->offsets[0] = sizeof(texture_t);
	r_notexture_mip->offsets[1] = r_notexture_mip->offsets[0] + 16*16;
	r_notexture_mip->offsets[2] = r_notexture_mip->offsets[1] + 8*8;
	r_notexture_mip->offsets[3] = r_notexture_mip->offsets[2] + 4*4;
	
	for (m=0 ; m<4 ; m++)
	{
		dest = (byte *)r_notexture_mip + r_notexture_mip->offsets[m];
		for (y=0 ; y< (16>>m) ; y++)
			for (x=0 ; x< (16>>m) ; x++)
			{
				if (  (y< (8>>m) ) ^ (x< (8>>m) ) )
					*dest++ = 0;
				else
					*dest++ = 0xff;
			}
	}	
}

/*
===============
R_Init
===============
*/
void R_Init (void)
{
	int		dummy;
	
// get stack position so we can guess if we are going to overflow
	r_stack_start = (byte *)&dummy;
	
	R_InitTurb ();
	
	Cmd_AddCommand ("timerefresh", R_TimeRefresh_f);	
	Cmd_AddCommand ("pointfile", R_ReadPointFile_f);	

	Cvar_RegisterVariable (&r_draworder);
	Cvar_RegisterVariable (&r_speeds);
	Cvar_RegisterVariable (&r_timegraph);
	Cvar_RegisterVariable (&r_graphheight);
	Cvar_RegisterVariable (&r_drawflat);
	Cvar_RegisterVariable (&r_cullsize);
	Cvar_RegisterVariable (&r_ambient);
	Cvar_RegisterVariable (&r_clearcolor);
	Cvar_RegisterVariable (&r_fastsky);
	Cvar_RegisterVariable (&r_flatwater);
	Cvar_RegisterVariable (&r_waterwarp);
	Cvar_RegisterVariable (&r_fullbright);
	Cvar_RegisterVariable (&r_dynamic);
	Cvar_RegisterVariable (&r_drawentities);
	Cvar_RegisterVariable (&r_drawviewmodel);
	Cvar_RegisterVariable (&r_drawparticles);
	Cvar_RegisterVariable (&r_hwspan);
	Cvar_RegisterVariable (&r_hwzspan);
	Cvar_RegisterVariable (&r_hwspan_queue);
	Cvar_RegisterVariable (&r_aliasstats);
	Cvar_RegisterVariable (&r_dspeeds);
	Cvar_RegisterVariable (&r_reportsurfout);
	Cvar_RegisterVariable (&r_maxsurfs);
	Cvar_RegisterVariable (&r_numsurfs);
	Cvar_RegisterVariable (&r_reportedgeout);
	Cvar_RegisterVariable (&r_maxedges);
	Cvar_RegisterVariable (&r_numedges);
	Cvar_RegisterVariable (&r_aliastransbase);
	Cvar_RegisterVariable (&r_aliastransadj);
	Cvar_RegisterVariable (&pq_cycleprof);

	Cvar_SetValue ("r_maxedges", (float)NUMSTACKEDGES);
	Cvar_SetValue ("r_maxsurfs", (float)NUMSTACKSURFACES);

	view_clipplanes[0].leftedge = true;
	view_clipplanes[1].rightedge = true;
	view_clipplanes[1].leftedge = view_clipplanes[2].leftedge =
			view_clipplanes[3].leftedge = false;
	view_clipplanes[0].rightedge = view_clipplanes[2].rightedge =
			view_clipplanes[3].rightedge = false;

	r_refdef.xOrigin = XCENTERING;
	r_refdef.yOrigin = YCENTERING;

	R_InitParticles ();

// TODO: collect 386-specific code in one place
#if	id386
	Sys_MakeCodeWriteable ((long)R_EdgeCodeStart,
					     (long)R_EdgeCodeEnd - (long)R_EdgeCodeStart);
#endif	// id386

	D_Init ();
}

/*
===============
R_NewMap
===============
*/
void R_NewMap (void)
{
	int		i;
	
// clear out efrags in case the level hasn't been reloaded
// FIXME: is this one short?
	for (i=0 ; i<cl.worldmodel->numleafs ; i++)
		cl.worldmodel->leafs[i].efrags = NULL;
		 	
	r_viewleaf = NULL;
	R_ClearParticles ();

	r_cnumsurfs = r_maxsurfs.value;

	if (r_cnumsurfs <= MINSURFACES)
		r_cnumsurfs = MINSURFACES;

	if (r_cnumsurfs > NUMSTACKSURFACES)
	{
		surfaces = Hunk_AllocName (r_cnumsurfs * sizeof(surf_t), "surfaces");
		surface_p = surfaces;
		surf_max = &surfaces[r_cnumsurfs];
		r_surfsonstack = false;
	// surface 0 doesn't really exist; it's just a dummy because index 0
	// is used to indicate no edge attached to surface
		surfaces--;
		R_SurfacePatch ();
	}
	else
	{
		r_surfsonstack = true;
	}

	r_maxedgesseen = 0;
	r_maxsurfsseen = 0;

	r_numallocatededges = r_maxedges.value;

	if (r_numallocatededges < MINEDGES)
		r_numallocatededges = MINEDGES;

	if (r_numallocatededges <= NUMSTACKEDGES)
	{
		auxedges = NULL;
	}
	else
	{
		auxedges = Hunk_AllocName (r_numallocatededges * sizeof(edge_t),
								   "edges");
	}

	r_dowarpold = false;
	r_viewchanged = false;
#ifdef PASSAGES
CreatePassages ();
#endif
}


/*
===============
R_SetVrect
===============
*/
void R_SetVrect (vrect_t *pvrectin, vrect_t *pvrect, int lineadj)
{
	int		h;
	float	size;

	size = scr_viewsize.value > 100 ? 100 : scr_viewsize.value;
	if (cl.intermission)
	{
		size = 100;
		lineadj = 0;
	}
	size /= 100;

	h = pvrectin->height - lineadj;
	pvrect->width = pvrectin->width * size;
	if (pvrect->width < 96)
	{
		size = 96.0 / pvrectin->width;
		pvrect->width = 96;	// min for icons
	}
	pvrect->width &= ~7;
	pvrect->height = pvrectin->height * size;
	if (pvrect->height > pvrectin->height - lineadj)
		pvrect->height = pvrectin->height - lineadj;

	pvrect->height &= ~1;

	pvrect->x = (pvrectin->width - pvrect->width)/2;
	pvrect->y = (h - pvrect->height)/2;

	{
		if (lcd_x.value)
		{
			pvrect->y >>= 1;
			pvrect->height >>= 1;
		}
	}
}


/*
===============
R_ViewChanged

Called every time the vid structure or r_refdef changes.
Guaranteed to be called before the first refresh
===============
*/
void R_ViewChanged (vrect_t *pvrect, int lineadj, float aspect)
{
	int		i;
	float	res_scale;

	r_viewchanged = true;

	R_SetVrect (pvrect, &r_refdef.vrect, lineadj);

	r_refdef.horizontalFieldOfView = 2.0 * tan (r_refdef.fov_x/360*M_PI);
	r_refdef.fvrectx = (float)r_refdef.vrect.x;
	r_refdef.fvrectx_adj = (float)r_refdef.vrect.x - 0.5;
	r_refdef.vrect_x_adj_shift20 = (r_refdef.vrect.x<<20) + (1<<19) - 1;
	r_refdef.fvrecty = (float)r_refdef.vrect.y;
	r_refdef.fvrecty_adj = (float)r_refdef.vrect.y - 0.5;
	r_refdef.vrectright = r_refdef.vrect.x + r_refdef.vrect.width;
	r_refdef.vrectright_adj_shift20 = (r_refdef.vrectright<<20) + (1<<19) - 1;
	r_refdef.fvrectright = (float)r_refdef.vrectright;
	r_refdef.fvrectright_adj = (float)r_refdef.vrectright - 0.5;
	r_refdef.vrectrightedge = (float)r_refdef.vrectright - 0.99;
	r_refdef.vrectbottom = r_refdef.vrect.y + r_refdef.vrect.height;
	r_refdef.fvrectbottom = (float)r_refdef.vrectbottom;
	r_refdef.fvrectbottom_adj = (float)r_refdef.vrectbottom - 0.5;

	r_refdef.aliasvrect.x = (int)(r_refdef.vrect.x * r_aliasuvscale);
	r_refdef.aliasvrect.y = (int)(r_refdef.vrect.y * r_aliasuvscale);
	r_refdef.aliasvrect.width = (int)(r_refdef.vrect.width * r_aliasuvscale);
	r_refdef.aliasvrect.height = (int)(r_refdef.vrect.height * r_aliasuvscale);
	r_refdef.aliasvrectright = r_refdef.aliasvrect.x +
			r_refdef.aliasvrect.width;
	r_refdef.aliasvrectbottom = r_refdef.aliasvrect.y +
			r_refdef.aliasvrect.height;

	pixelAspect = aspect;
	xOrigin = r_refdef.xOrigin;
	yOrigin = r_refdef.yOrigin;
	
	screenAspect = r_refdef.vrect.width*pixelAspect /
			r_refdef.vrect.height;
// 320*200 1.0 pixelAspect = 1.6 screenAspect
// 320*240 1.0 pixelAspect = 1.3333 screenAspect
// proper 320*200 pixelAspect = 0.8333333

	verticalFieldOfView = r_refdef.horizontalFieldOfView / screenAspect;

// values for perspective projection
// if math were exact, the values would range from 0.5 to to range+0.5
// hopefully they wll be in the 0.000001 to range+.999999 and truncate
// the polygon rasterization will never render in the first row or column
// but will definately render in the [range] row and column, so adjust the
// buffer origin to get an exact edge to edge fill
	xcenter = ((float)r_refdef.vrect.width * XCENTERING) +
			r_refdef.vrect.x - 0.5;
	aliasxcenter = xcenter * r_aliasuvscale;
	ycenter = ((float)r_refdef.vrect.height * YCENTERING) +
			r_refdef.vrect.y - 0.5;
	aliasycenter = ycenter * r_aliasuvscale;

	xscale = r_refdef.vrect.width / r_refdef.horizontalFieldOfView;
	aliasxscale = xscale * r_aliasuvscale;
	xscaleinv = 1.0 / xscale;
	yscale = xscale * pixelAspect;
	aliasyscale = yscale * r_aliasuvscale;
	yscaleinv = 1.0 / yscale;
	xscaleshrink = (r_refdef.vrect.width-6)/r_refdef.horizontalFieldOfView;
	yscaleshrink = xscaleshrink*pixelAspect;

// left side clip
	screenedge[0].normal[0] = -1.0 / (xOrigin*r_refdef.horizontalFieldOfView);
	screenedge[0].normal[1] = 0;
	screenedge[0].normal[2] = 1;
	screenedge[0].type = PLANE_ANYZ;
	
// right side clip
	screenedge[1].normal[0] =
			1.0 / ((1.0-xOrigin)*r_refdef.horizontalFieldOfView);
	screenedge[1].normal[1] = 0;
	screenedge[1].normal[2] = 1;
	screenedge[1].type = PLANE_ANYZ;
	
// top side clip
	screenedge[2].normal[0] = 0;
	screenedge[2].normal[1] = -1.0 / (yOrigin*verticalFieldOfView);
	screenedge[2].normal[2] = 1;
	screenedge[2].type = PLANE_ANYZ;
	
// bottom side clip
	screenedge[3].normal[0] = 0;
	screenedge[3].normal[1] = 1.0 / ((1.0-yOrigin)*verticalFieldOfView);
	screenedge[3].normal[2] = 1;	
	screenedge[3].type = PLANE_ANYZ;
	
	for (i=0 ; i<4 ; i++)
		VectorNormalize (screenedge[i].normal);

	res_scale = sqrtf((float)(r_refdef.vrect.width * r_refdef.vrect.height) /
			          (320.0f * 152.0f)) *
			(2.0f / r_refdef.horizontalFieldOfView);
	r_aliastransition = r_aliastransbase.value * res_scale;
	r_resfudge = r_aliastransadj.value * res_scale;

	if (scr_fov.value <= 90.0)
		r_fov_greater_than_90 = false;
	else
		r_fov_greater_than_90 = true;

// TODO: collect 386-specific code in one place
#if	id386
	if (r_pixbytes == 1)
	{
		Sys_MakeCodeWriteable ((long)R_Surf8Start,
						     (long)R_Surf8End - (long)R_Surf8Start);
		colormap = vid.colormap;
		R_Surf8Patch ();
	}
	else
	{
		Sys_MakeCodeWriteable ((long)R_Surf16Start,
						     (long)R_Surf16End - (long)R_Surf16Start);
		colormap = vid.colormap16;
		R_Surf16Patch ();
	}
#endif	// id386

	D_ViewChanged ();
}


/*
===============
R_MarkLeaves
===============
*/
void R_MarkLeaves (void)
{
	byte	*vis;
	mnode_t	*node;
	int		i;

	if (r_oldviewleaf == r_viewleaf)
		return;
	
	r_visframecount++;
	r_oldviewleaf = r_viewleaf;

	vis = Mod_LeafPVS (r_viewleaf, cl.worldmodel);
		
	for (i=0 ; i<cl.worldmodel->numleafs ; i++)
	{
		if (vis[i>>3] & (1<<(i&7)))
		{
			node = (mnode_t *)&cl.worldmodel->leafs[i+1];
			do
			{
				if (node->visframe == r_visframecount)
					break;
				node->visframe = r_visframecount;
				node = node->parent;
			} while (node);
		}
	}
}


/*
=============
R_DrawEntitiesOnList
=============
*/
void R_DrawEntitiesOnList (void)
{
	int			i, j;
	int			lnum;
	alight_t	lighting;
// FIXME: remove and do real lighting
	float		lightvec[3] = {-1, 0, 0};
	vec3_t		dist;
	float		add;

	if (!r_drawentities.value)
		return;

	for (i=0 ; i<cl_numvisedicts ; i++)
	{
		currententity = cl_visedicts[i];

		if (currententity == &cl_entities[cl.viewentity])
			continue;	// don't draw the player

		switch (currententity->model->type)
		{
		case mod_sprite:
			VectorCopy (currententity->origin, r_entorigin);
			VectorSubtract (r_origin, r_entorigin, modelorg);
			R_DrawSprite ();
			break;

		case mod_alias:
			VectorCopy (currententity->origin, r_entorigin);
			VectorSubtract (r_origin, r_entorigin, modelorg);

		// see if the bounding box lets us trivially reject, also sets
		// trivial accept status
			if (R_AliasCheckBBox ())
			{
				j = R_LightPoint (currententity->origin);
	
				lighting.ambientlight = j;
				lighting.shadelight = j;

				lighting.plightvec = lightvec;

				if (r_dynamic.value)
				{
					for (lnum=0 ; lnum<MAX_DLIGHTS ; lnum++)
					{
						if (cl_dlights[lnum].die >= cl.time)
						{
							VectorSubtract (currententity->origin,
											cl_dlights[lnum].origin,
											dist);
							add = cl_dlights[lnum].radius - Length(dist);
	
							if (add > 0)
								lighting.ambientlight += add;
						}
					}
				}
	
			// clamp lighting so it doesn't overbright as much
				if (lighting.ambientlight > 128)
					lighting.ambientlight = 128;
				if (lighting.ambientlight + lighting.shadelight > 192)
					lighting.shadelight = 192 - lighting.ambientlight;

				if (pq_cycleprof.value) {
					unsigned int prof_start = SYS_CYCLE_LO;
					R_AliasDrawModel (&lighting);
					pq_prof_alias_cycles_frame += (SYS_CYCLE_LO - prof_start);
				} else {
					R_AliasDrawModel (&lighting);
				}
			}

			break;

		default:
			break;
		}
	}
}

/*
=============
R_DrawViewModel
=============
*/
void R_DrawViewModel (void)
{
// FIXME: remove and do real lighting
	float		lightvec[3] = {-1, 0, 0};
	int			j;
	int			lnum;
	vec3_t		dist;
	float		add;
	dlight_t	*dl;
	
	if (!r_drawviewmodel.value || r_fov_greater_than_90)
		return;

	if (cl.items & IT_INVISIBILITY)
		return;

	if (cl.stats[STAT_HEALTH] <= 0)
		return;

	currententity = &cl.viewent;
	if (!currententity->model)
		return;

	VectorCopy (currententity->origin, r_entorigin);
	VectorSubtract (r_origin, r_entorigin, modelorg);

	VectorCopy (vup, viewlightvec);
	VectorInverse (viewlightvec);

	j = R_LightPoint (currententity->origin);

	if (j < 24)
		j = 24;		// allways give some light on gun
	r_viewlighting.ambientlight = j;
	r_viewlighting.shadelight = j;

// add dynamic lights
	if (r_dynamic.value)
	{
		for (lnum=0 ; lnum<MAX_DLIGHTS ; lnum++)
		{
			dl = &cl_dlights[lnum];
			if (!dl->radius)
				continue;
			if (!dl->radius)
				continue;
			if (dl->die < cl.time)
				continue;

			VectorSubtract (currententity->origin, dl->origin, dist);
			add = dl->radius - Length(dist);
			if (add > 0)
				r_viewlighting.ambientlight += add;
		}
	}

// clamp lighting so it doesn't overbright as much
	if (r_viewlighting.ambientlight > 128)
		r_viewlighting.ambientlight = 128;
	if (r_viewlighting.ambientlight + r_viewlighting.shadelight > 192)
		r_viewlighting.shadelight = 192 - r_viewlighting.ambientlight;

	r_viewlighting.plightvec = lightvec;

#ifdef QUAKE2
	cl.light_level = r_viewlighting.ambientlight;
#endif

	if (pq_cycleprof.value) {
		unsigned int prof_start = SYS_CYCLE_LO;
		R_AliasDrawModel (&r_viewlighting);
		pq_prof_alias_cycles_frame += (SYS_CYCLE_LO - prof_start);
	} else {
		R_AliasDrawModel (&r_viewlighting);
	}
}


/*
=============
R_BmodelCheckBBox
=============
*/
int R_BmodelCheckBBox (model_t *clmodel, float *minmaxs)
{
	int			i, *pindex, clipflags;
	vec3_t		acceptpt, rejectpt;
	float		d;

	clipflags = 0;

	if (currententity->angles[0] || currententity->angles[1]
		|| currententity->angles[2])
	{
		for (i=0 ; i<4 ; i++)
		{
			d = DotProduct (currententity->origin, view_clipplanes[i].normal);
			d -= view_clipplanes[i].dist;

			if (d <= -clmodel->radius)
				return BMODEL_FULLY_CLIPPED;

			if (d <= clmodel->radius)
				clipflags |= (1<<i);
		}
	}
	else
	{
		for (i=0 ; i<4 ; i++)
		{
		// generate accept and reject points
		// FIXME: do with fast look-ups or integer tests based on the sign bit
		// of the floating point values

			pindex = pfrustum_indexes[i];

			rejectpt[0] = minmaxs[pindex[0]];
			rejectpt[1] = minmaxs[pindex[1]];
			rejectpt[2] = minmaxs[pindex[2]];
			
			d = DotProduct (rejectpt, view_clipplanes[i].normal);
			d -= view_clipplanes[i].dist;

			if (d <= 0)
				return BMODEL_FULLY_CLIPPED;

			acceptpt[0] = minmaxs[pindex[3+0]];
			acceptpt[1] = minmaxs[pindex[3+1]];
			acceptpt[2] = minmaxs[pindex[3+2]];

			d = DotProduct (acceptpt, view_clipplanes[i].normal);
			d -= view_clipplanes[i].dist;

			if (d <= 0)
				clipflags |= (1<<i);
		}
	}

	return clipflags;
}


/*
=============
R_DrawBEntitiesOnList
=============
*/
void R_DrawBEntitiesOnList (void)
{
	int			i, j, k, clipflags;
	vec3_t		oldorigin;
	model_t		*clmodel;
	float		minmaxs[6];

	if (!r_drawentities.value)
		return;

	VectorCopy (modelorg, oldorigin);
	insubmodel = true;
	r_dlightframecount = r_framecount;

	for (i=0 ; i<cl_numvisedicts ; i++)
	{
		currententity = cl_visedicts[i];

		switch (currententity->model->type)
		{
		case mod_brush:

			clmodel = currententity->model;

		// see if the bounding box lets us trivially reject, also sets
		// trivial accept status
			for (j=0 ; j<3 ; j++)
			{
				minmaxs[j] = currententity->origin[j] +
						clmodel->mins[j];
				minmaxs[3+j] = currententity->origin[j] +
						clmodel->maxs[j];
			}

			clipflags = R_BmodelCheckBBox (clmodel, minmaxs);

			if (clipflags != BMODEL_FULLY_CLIPPED)
			{
				VectorCopy (currententity->origin, r_entorigin);
				VectorSubtract (r_origin, r_entorigin, modelorg);
			// FIXME: is this needed?
				VectorCopy (modelorg, r_worldmodelorg);
		
				r_pcurrentvertbase = clmodel->vertexes;
		
			// FIXME: stop transforming twice
				R_RotateBmodel ();

			// calculate dynamic lighting for bmodel if it's not an
			// instanced model
				if (r_dynamic.value && clmodel->firstmodelsurface != 0)
				{
					for (k=0 ; k<MAX_DLIGHTS ; k++)
					{
						if ((cl_dlights[k].die < cl.time) ||
							(!cl_dlights[k].radius))
						{
							continue;
						}

						R_MarkLights (&cl_dlights[k], 1<<k,
							clmodel->nodes + clmodel->hulls[0].firstclipnode);
					}
				}

			// if the driver wants polygons, deliver those. Z-buffering is on
			// at this point, so no clipping to the world tree is needed, just
			// frustum clipping
				if (r_drawpolys | r_drawculledpolys)
				{
					R_ZDrawSubmodelPolys (clmodel);
				}
				else
				{
					r_pefragtopnode = NULL;

					for (j=0 ; j<3 ; j++)
					{
						r_emins[j] = minmaxs[j];
						r_emaxs[j] = minmaxs[3+j];
					}

					R_SplitEntityOnNode2 (cl.worldmodel->nodes);

					if (r_pefragtopnode)
					{
						currententity->topnode = r_pefragtopnode;
	
						if (r_pefragtopnode->contents >= 0)
						{
						// not a leaf; has to be clipped to the world BSP
							r_clipflags = clipflags;
							R_DrawSolidClippedSubmodelPolygons (clmodel);
						}
						else
						{
						// falls entirely in one leaf, so we just put all the
						// edges in the edge list and let 1/z sorting handle
						// drawing order
							R_DrawSubmodelPolygons (clmodel, clipflags);
						}
	
						currententity->topnode = NULL;
					}
				}

			// put back world rotation and frustum clipping		
			// FIXME: R_RotateBmodel should just work off base_vxx
				VectorCopy (base_vpn, vpn);
				VectorCopy (base_vup, vup);
				VectorCopy (base_vright, vright);
				VectorCopy (base_modelorg, modelorg);
				VectorCopy (oldorigin, modelorg);
				R_TransformFrustum ();
			}

			break;

		default:
			break;
		}
	}

	insubmodel = false;
}


/*
================
PQ_Prof_DrawTerminal
================
*/
static void PQ_Prof_DrawTerminal(void)
{
	char line[48];
	int row = 0;

	term_clear();

	/* Header */
	term_setpos(row++, 0);
	term_puts("---- PocketQuake Profiler ----");

	/* Column header */
	term_setpos(row++, 0);
	term_puts("Function           Cycles    ms");

	/* Total frame */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Total         %10u %5u.%u",
		pq_prof_avg_total,
		pq_prof_avg_total / 100000,
		(pq_prof_avg_total / 10000) % 10);
	term_puts(line);

	/* R_EdgeDrawing */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "EdgeDrawing   %10u %5u.%u",
		pq_prof_avg_edge,
		pq_prof_avg_edge / 100000,
		(pq_prof_avg_edge / 10000) % 10);
	term_puts(line);

	/* RenderWorld (BSP traversal + edge emit) */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "  RenderWorld %10u %5u.%u",
		pq_prof_avg_renderworld,
		pq_prof_avg_renderworld / 100000,
		(pq_prof_avg_renderworld / 10000) % 10);
	term_puts(line);

	/* ScanEdges (includes Spans8+ZSpans) */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "  ScanEdges   %10u %5u.%u",
		pq_prof_avg_scanedges,
		pq_prof_avg_scanedges / 100000,
		(pq_prof_avg_scanedges / 10000) % 10);
	term_puts(line);

	/* Spans8 */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "    Spans8    %10u %5u.%u",
		pq_prof_avg_spans8,
		pq_prof_avg_spans8 / 100000,
		(pq_prof_avg_spans8 / 10000) % 10);
	term_puts(line);

	/* ZSpans */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "    ZSpans    %10u %5u.%u",
		pq_prof_avg_zspans,
		pq_prof_avg_zspans / 100000,
		(pq_prof_avg_zspans / 10000) % 10);
	term_puts(line);

	/* BEntities */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "  BEntities   %10u %5u.%u",
		pq_prof_avg_bentities,
		pq_prof_avg_bentities / 100000,
		(pq_prof_avg_bentities / 10000) % 10);
	term_puts(line);

	/* Alias */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Alias         %10u %5u.%u",
		pq_prof_avg_alias,
		pq_prof_avg_alias / 100000,
		(pq_prof_avg_alias / 10000) % 10);
	term_puts(line);

	/* R_DrawEntitiesOnList */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Entities      %10u %5u.%u",
		pq_prof_avg_entities,
		pq_prof_avg_entities / 100000,
		(pq_prof_avg_entities / 10000) % 10);
	term_puts(line);

	/* R_DrawViewModel */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "ViewModel     %10u %5u.%u",
		pq_prof_avg_viewmodel,
		pq_prof_avg_viewmodel / 100000,
		(pq_prof_avg_viewmodel / 10000) % 10);
	term_puts(line);

	/* R_SetupFrame */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "SetupFrame    %10u %5u.%u",
		pq_prof_avg_setup,
		pq_prof_avg_setup / 100000,
		(pq_prof_avg_setup / 10000) % 10);
	term_puts(line);

	/* R_MarkLeaves */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "MarkLeaves    %10u %5u.%u",
		pq_prof_avg_markleaves,
		pq_prof_avg_markleaves / 100000,
		(pq_prof_avg_markleaves / 10000) % 10);
	term_puts(line);

	/* Z-clear wait */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Z-clear wait  %10u %5u.%u",
		pq_prof_avg_zfill_wait,
		pq_prof_avg_zfill_wait / 100000,
		(pq_prof_avg_zfill_wait / 10000) % 10);
	term_puts(line);

	/* Particles */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Particles     %10u %5u.%u",
		pq_prof_avg_particles,
		pq_prof_avg_particles / 100000,
		(pq_prof_avg_particles / 10000) % 10);
	term_puts(line);

	/* D_WarpScreen */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "WarpScreen    %10u %5u.%u",
		pq_prof_avg_warp,
		pq_prof_avg_warp / 100000,
		(pq_prof_avg_warp / 10000) % 10);
	term_puts(line);

	/* Other/overhead */
	unsigned int accounted = pq_prof_avg_edge + pq_prof_avg_entities +
		pq_prof_avg_viewmodel + pq_prof_avg_setup +
		pq_prof_avg_markleaves + pq_prof_avg_zfill_wait +
		pq_prof_avg_particles + pq_prof_avg_warp;
	unsigned int other = (pq_prof_avg_total > accounted) ?
		pq_prof_avg_total - accounted : 0;
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Other         %10u %5u.%u",
		other, other / 100000, (other / 10000) % 10);
	term_puts(line);

	/* Blank separator */
	row++;

	/* Call counts */
	term_setpos(row++, 0);
	snprintf(line, sizeof(line), "Span calls: %u  Zspan: %u",
		pq_prof_avg_spans8_calls,
		pq_prof_avg_zspans_calls);
	term_puts(line);

	/* FPS estimate */
	unsigned int total_ms = pq_prof_avg_total / 100000;
	term_setpos(row++, 0);
	if (total_ms > 0)
		snprintf(line, sizeof(line), "~%u FPS (%u.%u ms/frame)",
			1000 / total_ms, total_ms,
			(pq_prof_avg_total / 10000) % 10);
	else
		snprintf(line, sizeof(line), "~999+ FPS");
	term_puts(line);
}

/*
================
R_EdgeDrawing
================
*/
/* Keep edge/surface scratch off the tiny BRAM stack.
 * On RV32 this function can otherwise allocate >100KB stack frame. */
static edge_t pq_ledge_scratch[NUMSTACKEDGES +
                               ((CACHE_SIZE - 1) / sizeof(edge_t)) + 1];
static surf_t pq_lsurf_scratch[NUMSTACKSURFACES +
                               ((CACHE_SIZE - 1) / sizeof(surf_t)) + 1];

PQ_FASTTEXT void R_EdgeDrawing (void)
{
	extern volatile unsigned int pq_dbg_stage;
	unsigned int prof_sub;
	int profiling = (int)pq_cycleprof.value;

	if (auxedges)
	{
		r_edges = auxedges;
	}
	else
	{
		r_edges =  (edge_t *)
				(((long)&pq_ledge_scratch[0] + CACHE_SIZE - 1) & ~(CACHE_SIZE - 1));
	}

	if (r_surfsonstack)
	{
		surfaces =  (surf_t *)
				(((long)&pq_lsurf_scratch[0] + CACHE_SIZE - 1) & ~(CACHE_SIZE - 1));
		surf_max = &surfaces[r_cnumsurfs];
	// surface 0 doesn't really exist; it's just a dummy because index 0
	// is used to indicate no edge attached to surface
		surfaces--;
		R_SurfacePatch ();
	}
	pq_dbg_stage = 0x3250;

	R_BeginEdgeFrame ();
	pq_dbg_stage = 0x3251;

	if (r_dspeeds.value)
	{
		rw_time1 = Sys_FloatTime ();
	}

	if (profiling)
		prof_sub = SYS_CYCLE_LO;
	R_RenderWorld ();
	if (profiling)
		pq_prof_renderworld_cycles_frame = SYS_CYCLE_LO - prof_sub;
	pq_dbg_stage = 0x3252;

	if (r_drawculledpolys)
		R_ScanEdges ();
	pq_dbg_stage = 0x3253;

// only the world can be drawn back to front with no z reads or compares, just
// z writes, so have the driver turn z compares on now
	D_TurnZOn ();
	pq_dbg_stage = 0x3254;

	if (r_dspeeds.value)
	{
		rw_time2 = Sys_FloatTime ();
		db_time1 = rw_time2;
	}

	if (profiling)
		prof_sub = SYS_CYCLE_LO;
	R_DrawBEntitiesOnList ();
	if (profiling)
		pq_prof_bentities_cycles_frame = SYS_CYCLE_LO - prof_sub;
	pq_dbg_stage = 0x3255;

	if (r_dspeeds.value)
	{
		db_time2 = Sys_FloatTime ();
		se_time1 = db_time2;
	}

	if (!r_dspeeds.value)
	{
		/* PocketQuake: skip mid-render audio extra update for stability. */
	}
	pq_dbg_stage = 0x3256;

	if (profiling)
		prof_sub = SYS_CYCLE_LO;
	if (!(r_drawpolys | r_drawculledpolys))
		R_ScanEdges ();
	if (profiling)
		pq_prof_scanedges_cycles_frame = SYS_CYCLE_LO - prof_sub;
	pq_dbg_stage = 0x3257;
}


/*
================
R_RenderView

r_refdef must be set before the first call
================
*/
void R_RenderView_ (void)
{
	extern volatile unsigned int pq_dbg_stage;
	byte	warpbuffer[WARP_WIDTH * WARP_HEIGHT];
	unsigned int prof_start;
	int profiling = (int)pq_cycleprof.value;

	r_warpbuffer = warpbuffer;

	// Clear z-buffer (cacheable SDRAM — memset goes through D-cache)
	memset(d_pzbuffer, 0, d_zwidth * vid.height * sizeof(short));

	if (profiling) {
		pq_prof_spans8_cycles_frame = 0;
		pq_prof_spans8_calls_frame = 0;
		pq_prof_zspans_cycles_frame = 0;
		pq_prof_zspans_calls_frame = 0;
		pq_prof_alias_cycles_frame = 0;
		pq_prof_edge_cycles_frame = 0;
		pq_prof_total_cycles_frame = 0;
		pq_prof_setup_cycles_frame = 0;
		pq_prof_markleaves_cycles_frame = 0;
		pq_prof_zfill_wait_cycles_frame = 0;
		pq_prof_entities_cycles_frame = 0;
		pq_prof_viewmodel_cycles_frame = 0;
		pq_prof_particles_cycles_frame = 0;
		pq_prof_warp_cycles_frame = 0;
		pq_prof_renderworld_cycles_frame = 0;
		pq_prof_scanedges_cycles_frame = 0;
		pq_prof_bentities_cycles_frame = 0;
		pq_prof_total_cycles_frame = SYS_CYCLE_LO; /* start of frame */
	}

	if (r_timegraph.value || r_speeds.value || r_dspeeds.value)
		r_time1 = Sys_FloatTime ();

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	R_SetupFrame ();
	if (profiling)
		pq_prof_setup_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x3201;

#ifdef PASSAGES
SetVisibilityByPassages ();
#else
	pq_dbg_stage = 0x3202;
	if (profiling)
		prof_start = SYS_CYCLE_LO;
	R_MarkLeaves ();	// done here so we know if we're in water
	if (profiling)
		pq_prof_markleaves_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x3203;
#endif

// make FDIV fast. This reduces timing precision after we've been running for a
// while, so we don't do it globally.  This also sets chop mode, and we do it
// here so that setup stuff like the refresh area calculations match what's
// done in screen.c
	/* No FPU mode switch needed on this target. */
	pq_dbg_stage = 0x3204;

	if (!cl_entities[0].model || !cl.worldmodel)
		Sys_Error ("R_RenderView: NULL worldmodel");
	pq_dbg_stage = 0x3205;

	if (!r_dspeeds.value)
	{
		S_ExtraUpdate ();
	}
	pq_dbg_stage = 0x3206;

	/* z-buffer clear is synchronous (memset), no wait needed */
	pq_prof_zfill_wait_cycles_frame = 0;

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	R_EdgeDrawing ();
	if (profiling)
		pq_prof_edge_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x3207;

	if (!r_dspeeds.value)
	{
		S_ExtraUpdate ();
	}
	pq_dbg_stage = 0x3208;

	if (r_dspeeds.value)
	{
		se_time2 = Sys_FloatTime ();
		de_time1 = se_time2;
	}
	pq_dbg_stage = 0x3209;

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	R_DrawEntitiesOnList ();
	if (profiling)
		pq_prof_entities_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x320A;

	if (r_dspeeds.value)
	{
		de_time2 = Sys_FloatTime ();
		dv_time1 = de_time2;
	}
	pq_dbg_stage = 0x320B;

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	R_DrawViewModel ();
	if (profiling)
		pq_prof_viewmodel_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x320C;

	if (r_dspeeds.value)
	{
		dv_time2 = Sys_FloatTime ();
		dp_time1 = Sys_FloatTime ();
	}
	pq_dbg_stage = 0x320D;

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	if (r_drawparticles.value)
		R_DrawParticles ();
	if (profiling)
		pq_prof_particles_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x320E;

	if (r_dspeeds.value)
		dp_time2 = Sys_FloatTime ();

	if (profiling)
		prof_start = SYS_CYCLE_LO;
	if (r_dowarp)
		D_WarpScreen ();
	if (profiling)
		pq_prof_warp_cycles_frame = SYS_CYCLE_LO - prof_start;
	pq_dbg_stage = 0x320F;

	if (profiling)
		pq_prof_total_cycles_frame = SYS_CYCLE_LO - pq_prof_total_cycles_frame;

	V_SetContentsColor (r_viewleaf->contents);

	if (r_timegraph.value)
		R_TimeGraph ();

	if (r_aliasstats.value)
		R_PrintAliasStats ();

	if (r_speeds.value)
		R_PrintTimes ();

	if (r_dspeeds.value)
		R_PrintDSpeeds ();

	if (r_reportsurfout.value && r_outofsurfaces)
		Con_Printf ("Short %d surfaces\n", r_outofsurfaces);

	if (r_reportedgeout.value && r_outofedges)
		Con_Printf ("Short roughly %d edges\n", r_outofedges * 2 / 3);

	if (profiling) {
		pq_prof_frame_counter++;

		if (profiling == 1) {
			/* Mode 1: existing Con_Printf every 30 frames */
			if ((pq_prof_frame_counter % 30) == 0) {
				Con_Printf ("pq_prof cyc edge:%u spans:%u z:%u alias:%u calls s:%u z:%u\n",
					pq_prof_edge_cycles_frame,
					pq_prof_spans8_cycles_frame,
					pq_prof_zspans_cycles_frame,
					pq_prof_alias_cycles_frame,
					pq_prof_spans8_calls_frame,
					pq_prof_zspans_calls_frame);
			}
		} else if (profiling == 2) {
			/* Mode 2: accumulate, average every 64 frames, draw terminal */
			pq_prof_total_accum += pq_prof_total_cycles_frame;
			pq_prof_setup_accum += pq_prof_setup_cycles_frame;
			pq_prof_markleaves_accum += pq_prof_markleaves_cycles_frame;
			pq_prof_zfill_wait_accum += pq_prof_zfill_wait_cycles_frame;
			pq_prof_edge_accum += pq_prof_edge_cycles_frame;
			pq_prof_entities_accum += pq_prof_entities_cycles_frame;
			pq_prof_viewmodel_accum += pq_prof_viewmodel_cycles_frame;
			pq_prof_particles_accum += pq_prof_particles_cycles_frame;
			pq_prof_warp_accum += pq_prof_warp_cycles_frame;
			pq_prof_spans8_accum += pq_prof_spans8_cycles_frame;
			pq_prof_zspans_accum += pq_prof_zspans_cycles_frame;
			pq_prof_alias_accum += pq_prof_alias_cycles_frame;
			pq_prof_spans8_calls_accum += pq_prof_spans8_calls_frame;
			pq_prof_zspans_calls_accum += pq_prof_zspans_calls_frame;
			pq_prof_renderworld_accum += pq_prof_renderworld_cycles_frame;
			pq_prof_scanedges_accum += pq_prof_scanedges_cycles_frame;
			pq_prof_bentities_accum += pq_prof_bentities_cycles_frame;

			if ((pq_prof_frame_counter & 63) == 0) {
				pq_prof_avg_total = pq_prof_total_accum >> 6;
				pq_prof_avg_setup = pq_prof_setup_accum >> 6;
				pq_prof_avg_markleaves = pq_prof_markleaves_accum >> 6;
				pq_prof_avg_zfill_wait = pq_prof_zfill_wait_accum >> 6;
				pq_prof_avg_edge = pq_prof_edge_accum >> 6;
				pq_prof_avg_entities = pq_prof_entities_accum >> 6;
				pq_prof_avg_viewmodel = pq_prof_viewmodel_accum >> 6;
				pq_prof_avg_particles = pq_prof_particles_accum >> 6;
				pq_prof_avg_warp = pq_prof_warp_accum >> 6;
				pq_prof_avg_spans8 = pq_prof_spans8_accum >> 6;
				pq_prof_avg_zspans = pq_prof_zspans_accum >> 6;
				pq_prof_avg_alias = pq_prof_alias_accum >> 6;
				pq_prof_avg_spans8_calls = pq_prof_spans8_calls_accum >> 6;
				pq_prof_avg_zspans_calls = pq_prof_zspans_calls_accum >> 6;
				pq_prof_avg_renderworld = pq_prof_renderworld_accum >> 6;
				pq_prof_avg_scanedges = pq_prof_scanedges_accum >> 6;
				pq_prof_avg_bentities = pq_prof_bentities_accum >> 6;

				pq_prof_total_accum = 0;
				pq_prof_setup_accum = 0;
				pq_prof_markleaves_accum = 0;
				pq_prof_zfill_wait_accum = 0;
				pq_prof_edge_accum = 0;
				pq_prof_entities_accum = 0;
				pq_prof_viewmodel_accum = 0;
				pq_prof_particles_accum = 0;
				pq_prof_warp_accum = 0;
				pq_prof_spans8_accum = 0;
				pq_prof_zspans_accum = 0;
				pq_prof_alias_accum = 0;
				pq_prof_spans8_calls_accum = 0;
				pq_prof_zspans_calls_accum = 0;
				pq_prof_renderworld_accum = 0;
				pq_prof_scanedges_accum = 0;
				pq_prof_bentities_accum = 0;

				PQ_Prof_DrawTerminal();
			}
		}
	}

	/* Display mode transitions for profiling mode 2 */
	if (profiling == 2 && pq_prof_prev_mode != 2) {
		/* Entering mode 2: switch to terminal display */
		SYS_DISPLAY_MODE = 0;
		term_clear();
		pq_prof_frame_counter = 0;
		pq_prof_total_accum = 0;
		pq_prof_setup_accum = 0;
		pq_prof_markleaves_accum = 0;
		pq_prof_zfill_wait_accum = 0;
		pq_prof_edge_accum = 0;
		pq_prof_entities_accum = 0;
		pq_prof_viewmodel_accum = 0;
		pq_prof_particles_accum = 0;
		pq_prof_warp_accum = 0;
		pq_prof_spans8_accum = 0;
		pq_prof_zspans_accum = 0;
		pq_prof_alias_accum = 0;
		pq_prof_spans8_calls_accum = 0;
		pq_prof_zspans_calls_accum = 0;
		pq_prof_renderworld_accum = 0;
		pq_prof_scanedges_accum = 0;
		pq_prof_bentities_accum = 0;
	} else if (profiling != 2 && pq_prof_prev_mode == 2) {
		/* Leaving mode 2: switch back to framebuffer */
		SYS_DISPLAY_MODE = 1;
	}
	pq_prof_prev_mode = profiling;

// back to high floating-point precision
	pq_dbg_stage = 0x3210;
}

void R_RenderView (void)
{
	extern volatile unsigned int pq_dbg_stage;
	int		dummy;
	int		delta;
	
	delta = (byte *)&dummy - r_stack_start;
	if (delta < -10000 || delta > 10000)
		Sys_Error ("R_RenderView: called without enough stack");

	if ( Hunk_LowMark() & 3 )
		Sys_Error ("Hunk is missaligned");

	if ( (long)(&dummy) & 3 )
		Sys_Error ("Stack is missaligned");

	if ( (long)(&r_warpbuffer) & 3 )
		Sys_Error ("Globals are missaligned");

	pq_dbg_stage = 0x3211;
	R_RenderView_ ();
	pq_dbg_stage = 0x3212;
}

/*
================
R_InitTurb
================
*/
void R_InitTurb (void)
{
	int		i;
	
	for (i=0 ; i<(SIN_BUFFER_SIZE) ; i++)
	{
		sintable[i] = AMP + sin(i*3.14159*2/CYCLE)*AMP;
		intsintable[i] = AMP2 + sin(i*3.14159*2/CYCLE)*AMP2;	// AMP2, not 20
	}
}
