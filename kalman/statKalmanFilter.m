function [X,P,Xp,Pp,rejSamples,logL]=statKalmanFilter(Y,A,C,Q,R,varargin)
%filterStationary implements a Kalman filter assuming
%stationary (fixed) noise matrices and system dynamics
%The model is: x[k+1]=A*x[k]+b+v[k], v~N(0,Q)
%y[k]=C*x[k]+d+w[k], w~N(0,R)
%And X[0] ~ N(x0,P0) -> Notice that this is different from other
%implementations, where P0 is taken to be cov(x[0|-1]) so x[0]~N(x0,A*P0*A'+Q)
%See for example Ghahramani and Hinton 1996
%Fast implementation by assuming that filter's steady-state is reached after 20 steps
%INPUTS:
%
%fastFlag: flag to indicate if fast smoothing should be performed. Default is no. Empty flag means no, any other value is yes.
%OUTPUTS:
%
%See also: statKalmanSmoother, statKalmanFilterConstrained, KFupdate, KFpredict

% For the filter to be well-defined, it is necessary that the quantity w=C'*inv(R+C*P*C')*y
% be well defined, for all observations y with some reasonable definition of inv().
% Naturally, this is the case if R+C*P*C' is invertible at each step. In
% turn, this is always the case if R is invertible, as P is positive semidef.
% There may exist situations where w is well defined even if R+C*P*C' is
% not invertible (which implies R is non inv). %This requires both: the
% projection of y and of the columns of C onto the 'uninvertible' subspace
% to be  always 0. In that case the output space can be 'compressed' to a
% smaller dimensional one by eliminating nuisance dimensions. This can be done because
% neither the state projects onto those dims, nor the observations fall in it.
% Such a reduction of the output space can be done for efficiency even if
% the projection of y is non-zero, provided that R is invertible and the
% structure of R decouples those dimensions from the rest (i.e. the
% observations along those dims are uncorrelated to the dims corresponding
% to the span of C). Naturally, this is a very special case, but there are
% some easy-to-test sufficient conditions: if R is diagonal, positive, and
% rank(C)<dim(R), compression is always possible.


[D2,N]=size(Y); D1=size(A,1);
%Init missing params:
[x0,P0,B,D,U,Ud,Ub,opts]=processKalmanOpts(D1,N,varargin);
M=processFastFlag(opts.fastFlag,A,N);

%TODO: Special case: deterministic system, no filtering needed. This can also be
%the case if Q << C'*R*C, and the system is stable

%Size checks:
%TODO

%Init arrays:
if isa(Y,'gpuArray') %For code to work on gpu
    Xp=nan(D1,N+1,'gpuArray');
    X=nan(D1,N,'gpuArray');
    Pp=nan(D1,D1,N+1,'gpuArray');
    P=nan(D1,D1,N,'gpuArray');
    rejSamples=zeros(D2,N,'gpuArray');
else
    Xp=nan(D1,N+1);
    X=nan(D1,N);
    Pp=nan(D1,D1,N+1);
    P=nan(D1,D1,N);
    rejSamples=zeros(D2,N);
end

%Priors:
prevX=x0; prevP=P0; Xp(:,1)=x0; Pp(:,:,1)=P0;

%Re-define observations to account for input effect:
Y_D=Y-D*Ud; BU=B*Ub;

%If D2>D1, then it is speedier to do a coordinate transform of the output:
%(it may also be convenient to do something if C is not full rank,as that
%means the output is also compressible). This is always safe if R is
%invertible, and may be safe in other situations, provided that
%observations never fall on the null-space of R.
if D2>D1 && ~opts.noReduceFlag %Reducing dimension of problem for speed
  %First, invert R:
  dimMargin=D2-D1;
  [icR]=pinvchol(R); %This works if R is semidefinite, but in general
  %semidefinite R is unworkable, as R+C*P*C' needs to be invertible.
  %Even assuming P invertible at each update, it still requires R to be
  %invertible for all vectors orthogonal to the span of C at least)
  %Second, reduce the dimensionality problem:
  J=C'*icR; %Cholesky-like decomp of C'*inv(R)*C
  R=J*J'; Y_D=J*icR'*Y_D; C=R; D2=D1;
  cR=mycholcov(R);
  logDetMargin=sum(log(diag(cR)))+sum(log(diag(icR)));
  %Some matrix determinant lemma matrix allows us to show that for any P:
  %det(R+C'*P*C)*det(R) = det(J*J' + (J*J')'*P*(J*J'))*det(J*J')
  %Thus, the difference between log(det(R+C'*P*C)) with the original and reduceModel
  %values is: deltaLog = log(det(R))-log(det(Rnew)). This permits to compute the logL
  %in the kalman filter on the reduced model, and then correct it by adding a constant
  %term, instead of recomputing it.
else
  cR=mycholcov(R);
  logDetMargin=0;
  dimMargin=0;
end
%Do the true filtering for M steps
rejSamples=false(N,1);
logL=nan(N,1);
if opts.outlierFlag
  rejThreshold=chi2inv(.99,D2);
else
  rejThreshold=[];
end
for i=1:M
  y=Y_D(:,i); %Output at this step

  %First, do the update given the output at this step:
  if ~any(isnan(y)) %If measurement is NaN, skip update.
      [prevX,prevP,K,logL(i),rejSamples(i)]=KFupdate(C,R,y,prevX,prevP,rejThreshold,cR);
  end
  X(:,i)=prevX;  P(:,:,i)=prevP; %Store results

  %Then, predict next step:
  [prevX,prevP]=KFpredict(A,Q,prevX,prevP,BU(:,i));
  if nargout>2 %Store Xp, Pp if requested:
      Xp(:,i+1)=prevX;   Pp(:,:,i+1)=prevP;
  end
end

if M<N %Do the fast filtering for any remaining steps:
%(from here on, we assume stady-state behavior to improve speed).
    %Steady-state matrices:
    prevX=X(:,M); Psteady=P(:,:,M); %Steady-state UPDATED state and uncertainty matrix
    Ksteady=K; %Steady-state Kalman gain
    Gsteady=eye(size(Ksteady,1))-Ksteady*C; %I-K*C,

    %Pre-compute matrices to reduce computing time:
    GBU_KY=Gsteady*BU(:,M:N-1)+Ksteady*Y_D(:,M+1:N); %The off-ordering is because we are doing predict (which depends on U(:,i-1)) and update (which depends on Y(:,i)
    GA=Gsteady*A;

    %Assign all UPDATED uncertainty matrices:
    P(:,:,M+1:end)=repmat(P(:,:,M),1,1,N-M);

    %Check that no outlier or fast flags are enabled
    if opts.outlierFlag || any(isnan(GBU_KY(:)))%Should never happen in fast mode
       error('KFfilter:outlierRejectFast','Outlier rejection is incompatible with fast mode.')
    end

    %Loop for remaining steps to compute x:
    for i=M+1:N
        gbu_ky=GBU_KY(:,i-M);
        prevX=GA*prevX+gbu_ky; %Predict+Update, in that order.
        %TODO: evaluate if this is good: because we dont compute y-C*X first
        %and then multiply by, K, we may be accumulating numerical errors in
        %cases where (y-C*x)==0
        X(:,i)=prevX;
    end
    if nargout>2 %Compute Xp, Pp only if requested:
        Xp(:,2:end)=A*X+B*Ub; Pp(:,:,M+2:end)=repmat(A*Psteady*A'+Q,1,1,size(Y,2)-M);
    end
end
log2Pi=1.83787706640934529;
logL=(nanmean(logL)+logDetMargin-.5*dimMargin*(log2Pi+1))/size(Y,1); %No idea why the +1 term is needed, but it is for the reduced dimension case to return the same value as the non-reduced case. WTF?
end
