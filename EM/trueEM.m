function [A,B,C,D,Q,R,X,P]=trueEM(Y,U,Xguess,targetLogL,fastFlag)
%A true EM implementation to do LTI-SSM identification
%INPUT:
%Y is D2 x N
%U is D3 x N
%Xguess - Either the number of states for the system (if scalar) or a guess
%at the initial states of the system (if D1 x N matrix)


[~,N]=size(Y);
if nargin<5 || isempty(fastFlag) || fastFlag==0
    fastFlag=false;
else
    fastFlag=true;
end

%Define init guess of state:
if numel(Xguess)==1 %Xguess is just dimension
    D1=Xguess;
    D=Y/U;
    if isa(Y,'gpuArray')
        [pp,~,~]=pca(gather(Y-D*U),'Centered','off'); %Can this be done in the gpu?
    else
       [pp,~,~]=pca((Y-D*U),'Centered','off'); %Can this be done in the gpu? 
    end
    Xguess=pp(:,1:D1)';
else %Xguess is an actual initial state
    D1=size(Xguess,1);
end
X=Xguess;

Niter=501;
%Move things to gpu if needed
if isa(Y,'gpuArray')
    Y=gpuArray(Y);
    U=gpuArray(U);
    X=gpuArray(X);
    P=zeros(D1,D1,N,'gpuArray');
    Pt=zeros(D1,D1,N-1,'gpuArray');
    logl=nan(Niter,1,'gpuArray');
else
    P=zeros(D1,D1,N);
    Pt=zeros(D1,D1,N-1);
    logl=nan(Niter,1);
end

%Initialize guesses of A,B,C,D,Q,R
[A1,B1,C1,D1,Q1,R1,x01,P01]=estimateParams(Y,U,X,P,Pt);
logl(1,1)=dataLogLikelihood(Y,U,A1,B1,C1,D1,Q1,R1,x01,P01);
%[A1,B1,C1,x01,~,Q1] = canonizev3(A1,B1,C1,x01,Q1); %Make sure scaling is good
A=A1; B=B1; C=C1; D=D1; Q=Q1; R=R1;

if nargin<4 || isempty(targetLogL)
    targetLogL=logl(1);
end
failCounter=0;
%Now, do E-M
for k=1:size(logl,1)-1
	%E-step: compute the expectation of latent variables given current parameter estimates
    %Note this is an approximation of true E-step in E-M algorithm. The
    %E-step requires to compute the expectation of the likelihood of the data under the
    %latent variables = E(L(Y,X|params)), to then maximize it
    %whereas here we are computing E(X|params) to then maximize L(Y,E(X)|params)
    %logl(k,2)=dataLogLikelihood(Y,U,A,B,C,D,Q,R,X);
	%M-step: find parameters A,B,C,D,Q,R that maximize likelihood of data
    
    %E-step:
    if ~fastFlag
        [X1,P1,Pt1,~,~,Xp,Pp,~]=statKalmanSmoother(Y,A1,C1,Q1,R1,x01,P01,B1,D1,U);
    else
        [X1,P1,Pt1,~,~,Xp,Pp,~]=statKalmanSmootherFast(Y,A1,C1,Q1,R1,x01,P01,B1,D1,U);
    end
    if any(imag(X1(:)))~=0
       error('Complex states') 
    end
    
    %Check improvements:
    %l=dataLogLikelihood(Y,U,A1,B1,C1,D1,Q1,R1,Xp,Pp); %Passing the Kalman-filtered states and uncertainty makes the computation more efficient
    predError=Y-C1*Xp(:,1:end-1)-D1*U; %One-step ahead prediction error of model
    l=fastLogL(predError);
    logl(k+1)=l;
    improvement=l>=logl(k,1);
    targetRelImprovement=(l-logl(k,1))/(targetLogL-l);
    belowTarget=l<targetLogL;
    relImprovementLast10=1-logl(max(k-10,1),1)/l; %Assessing the relative improvement on logl over the last 10 iterations (or less if there aren't as many)
    
    %Check for failure conditions:
    if imag(l)~=0
        warning(['Complex logL, probably ill-conditioned matrices involved. Stopping after ' num2str(k) ' iterations.'])
        break
    elseif ~improvement %This should never happen, except that our loglikelihood is approximate, so there can be some rounding error
        warning(['logL decreased at iteration ' num2str(k) ', drop = ' num2str(l-logl(k,1))])
        failCounter=failCounter+1;
        %TO DO: figure out why logl sometimes drops a lot on iter 1.
        if failCounter>4
            fprintf(['Dropped 5 times w/o besting the fit. ' num2str(k) ' iterations.\n'])
            break
        end
    else %There was improvement
        if l>=max(logl)
            failCounter=0;
            %If everything went well and these parameters are the best ever: 
            %replace parameters  (notice the algorithm
            %may continue even if the logl dropped, but in that case we do not
            %save the parameters)
            A=A1; B=B1; C=C1; D=D1; Q=Q1; R=R1; x0=x01; P0=P01; X=X1; P=P1; %Pt=Pt1;
        end
    end

    %Check if we should stop early (to avoid wasting time):
    if k>1 && (belowTarget && (targetRelImprovement)<2e-2) %Breaking if improvement less than 2% of distance to targetLogL, as this probably means we are not getting a solution better than the given target
       fprintf(['unlikely to reach target value. ' num2str(k) ' iterations.\n'])
       break 
    elseif k>1 && (relImprovementLast10)<1e-7 %Considering the system stalled if relative improvement on logl is <1e-7
        fprintf(['increase is within tolerance (local max). '  num2str(k) ' iterations.\n'])
        %disp(['LogL as % of target:' num2str(round(l*100000/targetLogL)/1000)])
        break 
    end
    
    %M-step:
    [A1,B1,C1,D1,Q1,R1,x01,P01]=estimateParams(Y,U,X1,P1,Pt1);
end
end

function maxLperSample=fastLogL(predError)
%A fast implementation of the logL when we assume R is set to be optimal 
%over PSD matrices
%Computing in this way is faster, and avoids dealing with numerical issues
%arising from the attempt to compute the optimal R within trueEM.
%See dataLogLikelihood for the exact logl() function and the conditions 
%for this assumption
%INPUT:
%predError: the one-step ahead prediction errors for the model
    [D2,N2]=size(predError);
    S=predError*predError'/N2;
    logdetS=sum(log(eig(S)));
    maxLperSample = -.5*(D2+logdetS+D2*log(2*pi));
end