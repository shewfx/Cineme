from typing import Annotated

from fastapi import APIRouter, Depends, Path, Query, Request
from sqlalchemy.orm import Session

from app.core.auth import Identity, current_identity
from app.core.db import get_session

from . import service
from .provider import MovieMetadataProvider
from .schemas import GenreOut, GenresResponse, MovieDetails, SearchResponse

router = APIRouter(prefix="/api/v1", tags=["movies"])

CallerIdentity = Annotated[Identity, Depends(current_identity)]
DbSession = Annotated[Session, Depends(get_session)]


def get_provider(request: Request) -> MovieMetadataProvider:
    provider: MovieMetadataProvider = request.app.state.movie_provider
    return provider


Provider = Annotated[MovieMetadataProvider, Depends(get_provider)]


@router.get("/movies/search", response_model=SearchResponse)
def search_movies(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    q: Annotated[str, Query(min_length=2, max_length=100)],
    page: Annotated[int, Query(ge=1, le=500)] = 1,
) -> SearchResponse:
    """TMDB search through the backend; the TMDB token never reaches Flutter."""
    return service.search(session, provider, identity.user_id, q.strip(), page)


@router.get("/movies/{tmdb_id}", response_model=MovieDetails)
def movie_details(
    identity: CallerIdentity,
    session: DbSession,
    provider: Provider,
    tmdb_id: Annotated[int, Path(gt=0, le=2_147_483_647)],
) -> MovieDetails:
    """May refresh the shared metadata cache; never touches private data."""
    return service.details(session, provider, identity.user_id, tmdb_id)


@router.get("/genres", response_model=GenresResponse)
def genres(identity: CallerIdentity, provider: Provider) -> GenresResponse:
    return GenresResponse(
        items=[GenreOut(id=g.id, name=g.name) for g in service.genre_list(provider)],
        version="tmdb_genres_v1",
    )
